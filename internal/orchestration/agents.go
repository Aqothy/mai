package orchestration

import (
	"context"
	"slices"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// The agent API: what maiD's MCP tools call, running as the calling
// agent. Spawn, send, stop, respond and report are commands (Do with an
// agent actor); agents, read and wait are reads, here.

// AgentChoice is an agent the caller may start.
type AgentChoice struct {
	Instance  provider.InstanceID    `json:"id"`
	Name      string                 `json:"name"`
	Driver    provider.DriverKind    `json:"driver"`
	Models    []string               `json:"models"`
	Access    []provider.AccessLevel `json:"accessLevels"`
	Available bool                   `json:"available"`
	Reason    string                 `json:"reason,omitempty"`
}

// Self is the calling agent as maiD sees it.
type Self struct {
	Thread ThreadID             `json:"thread"`
	Agent  ParticipantID        `json:"agent"`
	Access provider.AccessLevel `json:"access,omitempty"`
	Depth  int                  `json:"depth"`
}

// Agents lists what the caller may start, the unavailable with why.
func (e *Engine) Agents(ctx context.Context, caller Actor, instances []provider.InstanceInfo) (Self, []AgentChoice, error) {
	type out struct {
		self    Self
		ceiling provider.AccessLevel
		atDepth bool
	}
	got, err := call(ctx, e, func(s *step) (out, error) {
		thread := e.threads[caller.Thread]
		participant := e.participants[caller.Participant]
		if thread == nil || participant == nil {
			return out{}, refused(CodeNotFound, "the calling agent no longer exists")
		}
		level := e.accessLevel(participant)
		return out{
			self:    Self{Thread: thread.ID, Agent: participant.ID, Access: level, Depth: e.depth(thread)},
			ceiling: level.Ceiling(), atDepth: e.depth(thread)+1 > e.policy(thread).MaxDepth,
		}, nil
	})
	if err != nil {
		return Self{}, nil, err
	}
	choices := make([]AgentChoice, 0, len(instances))
	for _, info := range instances {
		choice := AgentChoice{Instance: info.InstanceID, Name: info.Name, Driver: info.Driver, Models: []string{}, Access: []provider.AccessLevel{}, Available: true}
		if info.Access != nil {
			for _, level := range info.Access.Levels {
				if !level.Exceeds(got.ceiling) && !slices.Contains(choice.Access, level) {
					choice.Access = append(choice.Access, level)
				}
			}
			slices.SortFunc(choice.Access, func(a, b provider.AccessLevel) int { return a.Rank() - b.Rank() })
		}
		switch {
		case got.atDepth:
			choice.Available, choice.Reason = false, "you are at the deepest level chats may go"
		case info.Status == provider.InstanceStatusExited:
			choice.Available, choice.Reason = false, "it isn't running"
		case info.Auth.Status == provider.AuthStatusUnauthenticated:
			choice.Available, choice.Reason = false, "it is signed out"
		case info.Access == nil && provider.AccessFull.Exceeds(got.ceiling):
			choice.Available, choice.Reason = false, "its access modes aren't mapped, so it counts as full access, beyond yours"
		case info.Access != nil && len(choice.Access) == 0:
			choice.Available, choice.Reason = false, "it has no mode within your access"
		}
		choices = append(choices, choice)
	}
	return got.self, choices, nil
}

// mayRead: an agent reads its ancestors, its descendants, the threads its
// chat's agents are in, and threads in its workspace.
func (e *Engine) mayRead(actor Actor, thread *threadState) bool {
	if actor.Kind == ActorDevice {
		return true
	}
	caller := e.threads[actor.Thread]
	if caller == nil {
		return false
	}
	return thread.ID == caller.ID || e.isAncestor(thread.ID, caller) || e.isAncestor(caller.ID, thread) ||
		thread.Workspace.Cwd == caller.Workspace.Cwd
}

// WaitThread is one watched thread in a wait's result.
type WaitThread struct {
	Thread ThreadID     `json:"thread"`
	Status ThreadStatus `json:"status"`
	// Reply is the answer the thread owes the caller, taken by returning it.
	Reply      *Answer       `json:"reply,omitempty"`
	NeedsInput []RequestView `json:"needsInput,omitempty"`
}

type WaitResult struct {
	Threads  []WaitThread `json:"threads"`
	TimedOut bool         `json:"timedOut"`
}

type waiter struct {
	caller   Actor
	threads  []ThreadID
	all      bool
	deadline time.Time
	done     chan WaitResult
}

// Wait returns once the caller's watched threads (any of them, or all) are
// done with what it sent them, any of them needs input, or the timeout
// passes. A reply returned is taken: it isn't delivered again as a wake.
// The calling turn doesn't count toward its tree's MaxRunning meanwhile.
func (e *Engine) Wait(ctx context.Context, caller Actor, threads []ThreadID, all bool, timeout time.Duration) (WaitResult, error) {
	done := make(chan WaitResult, 1)
	id, err := call(ctx, e, func(s *step) (uint64, error) {
		for _, id := range threads {
			thread, err := e.existing(id)
			if err != nil {
				return 0, err
			}
			if !e.mayRead(caller, thread) {
				return 0, refused(CodeOutOfScope, "you can't read chat %q", id)
			}
		}
		e.nextWait++
		e.waits[e.nextWait] = &waiter{caller: caller, threads: slices.Clone(threads), all: all, deadline: s.now.Add(timeout), done: done}
		if thread := e.threads[caller.Thread]; thread != nil {
			s.touch(thread.ID)
		}
		e.wakeWaits(s)
		return e.nextWait, nil
	})
	if err != nil {
		return WaitResult{}, err
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case result := <-done:
		return result, nil
	case <-timer.C:
	case <-ctx.Done():
	}
	// Timed out or abandoned: one last look takes any reply now owed, so it
	// isn't lost between the timeout and the wake.
	result, err := call(context.Background(), e, func(s *step) (WaitResult, error) {
		w := e.waits[id]
		if w == nil {
			return <-done, nil
		}
		delete(e.waits, id)
		e.touchWait(s, w)
		result, _ := e.evaluateWait(s, w, true)
		return result, nil
	})
	if err != nil {
		return WaitResult{}, err
	}
	if ctx.Err() != nil {
		return result, ctx.Err()
	}
	return result, nil
}

// wakeWaits re-evaluates waits once the step commits.
func (e *Engine) wakeWaits(s *step) {
	if len(e.waits) == 0 {
		return
	}
	s.after(func() {
		e.post(func(s *step) {
			for id, w := range e.waits {
				if result, done := e.evaluateWait(s, w, false); done {
					delete(e.waits, id)
					e.touchWait(s, w)
					s.after(func() { w.done <- result })
				}
			}
		})
	})
}

// touchWait lets the reactors look again at what a wait held back: its
// caller's slot and the replies it would have taken.
func (e *Engine) touchWait(s *step, w *waiter) {
	for _, id := range append([]ThreadID{w.caller.Thread}, w.threads...) {
		if e.threads[id] != nil {
			s.touch(id)
		}
	}
}

// evaluateWait reports a wait's result and whether its condition holds;
// final takes the replies owed even when it doesn't.
func (e *Engine) evaluateWait(s *step, w *waiter, final bool) (WaitResult, bool) {
	result := WaitResult{Threads: []WaitThread{}}
	ready, needsInput := 0, false
	for _, id := range w.threads {
		thread := e.threads[id]
		if thread == nil {
			ready++
			continue
		}
		watched := WaitThread{Thread: id, Status: e.status(thread)}
		for _, request := range sortedRequests(thread) {
			watched.NeedsInput = append(watched.NeedsInput, requestView(request))
		}
		for _, child := range e.descendants(thread) {
			for _, request := range sortedRequests(child) {
				watched.NeedsInput = append(watched.NeedsInput, requestView(request))
			}
		}
		if len(watched.NeedsInput) > 0 {
			needsInput = true
		}
		if !e.busy(thread, true) {
			ready++
		}
		result.Threads = append(result.Threads, watched)
	}
	done := needsInput || w.all && ready == len(w.threads) || !w.all && ready > 0
	if !done && !final {
		return result, false
	}
	for index := range result.Threads {
		if thread := e.threads[result.Threads[index].Thread]; thread != nil {
			result.Threads[index].Reply = e.takeReply(s, thread, w.caller)
		}
	}
	result.TimedOut = !done
	return result, true
}

// takeReply takes the answer a thread owes the caller, if it owes one now:
// its row is the reply, sending until the caller's turn ends with it, so a
// crash before then probes for it and wakes the caller with it instead.
func (e *Engine) takeReply(s *step, thread *threadState, caller Actor) *Answer {
	if e.busy(thread, false) {
		return nil
	}
	for _, message := range slices.Clone(thread.awaiting) {
		if message.From.Participant != caller.Participant {
			continue
		}
		sender := e.threads[caller.Thread]
		if sender == nil {
			return nil
		}
		answer := e.answer(thread, message)
		e.dropAwaiting(thread, message.ID)
		reply := &Delivery{
			ID: DeliveryID(newID()), Thread: sender.ID, To: caller.Participant, From: Agent(thread.ID, message.To),
			Kind: KindReply, Mode: ModeQueue, State: DeliverySending, Answers: message.ID, Answer: &answer,
			Position: e.nextPosition(sender), CreatedAt: s.now, Sent: s.now,
		}
		if running := sender.runningTurn(); running != nil {
			reply.Turn = running.ID
		}
		sender.queue = append(sender.queue, reply)
		s.putDelivery(reply)
		return &answer
	}
	return nil
}

// waiting reports whether a thread's agent is blocked in a wait.
func (e *Engine) waiting(thread ThreadID) bool {
	for _, w := range e.waits {
		if w.caller.Thread == thread {
			return true
		}
	}
	return false
}

// waitedBy reports whether a wait of the participant watches a thread.
func (e *Engine) waitedBy(thread ThreadID, participant ParticipantID) bool {
	for _, w := range e.waits {
		if w.caller.Participant == participant && slices.Contains(w.threads, thread) {
			return true
		}
	}
	return false
}

// watched reports whether some wait watches a thread.
func (e *Engine) watched(thread ThreadID) bool {
	for _, w := range e.waits {
		if slices.Contains(w.threads, thread) {
			return true
		}
	}
	return false
}

func (e *Engine) forgetWaits(thread ThreadID) {
	for id, w := range e.waits {
		if w.caller.Thread == thread {
			delete(e.waits, id)
			close(w.done)
		}
	}
}

// ReadResult is a page of a thread's conversation for an agent.
type ReadResult struct {
	Entries      []EntryView          `json:"entries"`
	Next         TurnID               `json:"next,omitempty"`
	Status       ThreadStatus         `json:"status"`
	Participants []ParticipantSummary `json:"participants"`
	// Reply is the answer the thread owes the caller, taken by reading it.
	Reply *Answer `json:"reply,omitempty"`
}

// Read returns a thread's entries in turns after a turn, bounded like a
// snapshot.
func (e *Engine) Read(ctx context.Context, caller Actor, id ThreadID, after TurnID, limit int) (ReadResult, error) {
	type head struct {
		status       ThreadStatus
		participants []ParticipantSummary
		instances    map[ParticipantID]provider.InstanceID
		reply        *Answer
		running      *Turn
		live         []provider.Entry
	}
	got, err := call(ctx, e, func(s *step) (head, error) {
		thread, err := e.existing(id)
		if err != nil {
			return head{}, err
		}
		if !e.mayRead(caller, thread) {
			return head{}, refused(CodeOutOfScope, "you can't read chat %q", id)
		}
		out := head{status: e.status(thread), instances: make(map[ParticipantID]provider.InstanceID), participants: []ParticipantSummary{}}
		for _, pid := range thread.participants {
			participant := e.participants[pid]
			out.participants = append(out.participants, e.participantSummary(participant))
			out.instances[pid] = participant.Instance
		}
		if caller.Kind == ActorAgent {
			out.reply = e.takeReply(s, thread, caller)
		}
		if running := thread.runningTurn(); running != nil && thread.entries != nil {
			copied := *running
			out.running, out.live = &copied, thread.entries.list()
		}
		return out, nil
	})
	if err != nil {
		return ReadResult{}, err
	}
	if limit <= 0 || limit > snapshotEntries {
		limit = snapshotEntries
	}
	turns, err := e.db.threadTurns(ctx, id, nil, 0)
	if err != nil {
		return ReadResult{}, err
	}
	start := 0
	for index, turn := range turns {
		if turn.ID == after {
			start = index + 1
		}
	}
	result := ReadResult{Entries: []EntryView{}, Status: got.status, Participants: got.participants, Reply: got.reply}
	for _, turn := range turns[start:] {
		var entries []provider.Entry
		if got.running != nil && turn.ID == got.running.ID {
			entries = got.live
		} else if entries, err = e.db.turnEntries(ctx, got.instances[turn.Participant], turn.Session, turn.Ref); err != nil {
			return ReadResult{}, err
		}
		if len(result.Entries)+len(entries) > limit && len(result.Entries) > 0 {
			break
		}
		result.Entries = append(result.Entries, entryViews(entries)...)
		if turn.State.Settled() {
			result.Next = turn.ID
		}
	}
	return result, nil
}
