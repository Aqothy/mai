package orchestration

import (
	"context"
	"slices"

	"github.com/Aqothy/maiD/internal/provider"
)

// Reactors are level-triggered rules from the current state to the engine's
// own acts. After every step commits they run for the threads it
// touched and their ancestors, until nothing more changes, and all of them
// run at startup, so a crash at any point converges.

// maxReactorRounds bounds reactions to reactions after one step; rules only
// move state forward, so a few rounds settle any step.
const maxReactorRounds = 8

// react runs the rules for the due threads and their ancestors. What they
// touch is due next round.
func (e *Engine) react(s *step, touched map[ThreadID]bool) {
	due := make(map[ThreadID]bool)
	for id := range touched {
		if thread := e.threads[id]; thread != nil {
			due[id] = true
			for _, ancestor := range e.ancestors(thread) {
				due[ancestor.ID] = true
			}
		}
	}
	ids := make([]ThreadID, 0, len(due))
	for id := range due {
		ids = append(ids, id)
	}
	slices.Sort(ids)
	for _, id := range ids {
		if thread := e.threads[id]; thread != nil {
			e.reactThread(s, thread)
		}
	}
}

func (e *Engine) reactThread(s *step, thread *threadState) {
	e.replyReactor(s, thread)
	e.needsInputReactor(s, thread)
	e.steerReactor(s, thread)
	e.hopReactor(s, thread)
	e.floorReactor(s, thread)
}

// floorReactor starts a thread's next turn: when it doesn't run and nothing
// holds it, the queued delivery with the lowest position goes, its
// participant's session opened first. A delivery an agent or the daemon
// sent waits while its tree already runs MaxRunning agent-started turns; a
// person's never waits, except for a hold on its instance.
func (e *Engine) floorReactor(s *step, thread *threadState) {
	if thread.running() || thread.Hold != HoldNone {
		return
	}
	queued := thread.queued()
	if len(queued) == 0 {
		return
	}
	next := queued[0]
	if participant := e.participants[next.To]; participant != nil && e.instanceHeld(participant.Instance) {
		return
	}
	if next.From.Kind != ActorDevice && e.agentTurnsRunning(thread) >= e.policy(thread).MaxRunning {
		return
	}
	e.startDelivery(s, thread, next, false)
}

// agentTurnsRunning counts the tree's threads running agent-started turns,
// leaving out turns blocked in a wait call, so a parent waiting on its
// children never holds the slot they need.
func (e *Engine) agentTurnsRunning(thread *threadState) int {
	root := e.root(thread)
	count := 0
	for _, candidate := range append([]*threadState{root}, e.descendants(root)...) {
		running := candidate.runningTurn()
		if running != nil && running.ByAgent && !e.waiting(candidate.ID) {
			count++
		}
		for _, delivery := range candidate.queue {
			if delivery.State == DeliverySending && delivery.From.Kind != ActorDevice && running == nil {
				count++
			}
		}
	}
	return count
}

// steerReactor sends queued steers into the running turn of the participant
// they are for, where its provider can steer. Elsewhere a steer waits and
// starts the next turn.
func (e *Engine) steerReactor(s *step, thread *threadState) {
	running := thread.runningTurn()
	if running == nil || thread.interrupting != nil || thread.Hold != HoldNone {
		return
	}
	participant := e.participants[running.Participant]
	if participant == nil || participant.live == nil && thread.Origin.Kind != OriginNative || !e.instanceInfo(participant.Instance).Capabilities.Steer {
		return
	}
	for _, delivery := range thread.queued() {
		if delivery.Mode == ModeSteer && delivery.To == running.Participant {
			e.startDelivery(s, thread, delivery, true)
		}
	}
}

// hopReactor holds a thread whose next delivery would start a turn past its
// tree's hop limit: agents went back and forth too long without a person.
func (e *Engine) hopReactor(s *step, thread *threadState) {
	if thread.Hold != HoldNone || thread.running() {
		return
	}
	queued := thread.queued()
	if len(queued) == 0 || queued[0].From.Kind == ActorDevice {
		return
	}
	if queued[0].Hops > e.policy(thread).HopLimit {
		thread.Hold = HoldHops
		s.putThread(thread)
	}
}

// replyReactor answers the messages a thread was sent once it is done with
// them: it doesn't run and has nothing queued, and, unless the sender
// is below it, nothing below it runs or waits. The answer goes back to the
// sender, a steer if the sender's turn still runs, else a new turn.
func (e *Engine) replyReactor(s *step, thread *threadState) {
	if len(thread.awaiting) == 0 || thread.running() || len(thread.queued()) > 0 {
		return
	}
	descendantsBusy := e.busy(thread, true)
	for _, message := range slices.Clone(thread.awaiting) {
		sender := e.threads[message.From.Thread]
		if sender == nil || e.participants[message.From.Participant] == nil {
			e.dropAwaiting(thread, message.ID)
			continue
		}
		if descendantsBusy && !e.isAncestor(thread.ID, sender) {
			continue
		}
		// A wait of the sender watching the thread takes the answer itself.
		if e.waitedBy(thread.ID, message.From.Participant) {
			continue
		}
		turn, ok, err := e.db.turn(e.ctx, message.Turn)
		if err != nil || !ok {
			e.dropAwaiting(thread, message.ID)
			continue
		}
		if turn.State == provider.TurnRunning {
			continue
		}
		answer := e.answer(thread, message)
		e.queueReply(s, thread, sender, message, answer)
	}
}

func (e *Engine) dropAwaiting(thread *threadState, id DeliveryID) {
	thread.awaiting = slices.DeleteFunc(thread.awaiting, func(delivery *Delivery) bool { return delivery.ID == id })
}

// queueReply sends a message's answer to its sender, unless a wait or read
// already took it.
func (e *Engine) queueReply(s *step, thread, sender *threadState, message *Delivery, answer Answer) {
	e.dropAwaiting(thread, message.ID)
	if _, taken, err := e.db.replyTo(e.ctx, message.ID); err != nil || taken {
		return
	}
	mode := ModeQueue
	if running := sender.runningTurn(); running != nil && running.Participant == message.From.Participant {
		mode = ModeSteer
	}
	hops := 0
	if thread.latest != nil {
		hops = thread.latest.Hops
	}
	reply := &Delivery{
		ID: DeliveryID(newID()), Thread: sender.ID, To: message.From.Participant, From: Agent(thread.ID, message.To),
		Kind: KindReply, Mode: mode, State: DeliveryQueued, Hops: hops, Answers: message.ID, Answer: &answer,
		Position: e.nextPosition(sender), CreatedAt: s.now,
	}
	sender.queue = append(sender.queue, reply)
	s.putDelivery(reply)
	e.notifyDelivery(s, sender, reply)
}

// answer is what a thread answers a message with: its last assistant
// message (a failed turn's error first) and its last report since the
// message.
func (e *Engine) answer(thread *threadState, message *Delivery) Answer {
	answer := Answer{State: provider.TurnCompleted, Reported: true}
	latest := thread.latest
	if latest == nil {
		return answer
	}
	answer.State = latest.State
	if latest.State == provider.TurnFailed && latest.Error != "" {
		answer.Text = latest.Error + "\n\n"
	}
	participant := e.participants[latest.Participant]
	if participant != nil {
		entries, _ := e.db.turnEntries(e.ctx, participant.Instance, latest.Session, latest.Ref)
		for index := len(entries) - 1; index >= 0; index-- {
			if entries[index].Kind == provider.ItemKindAssistantMessage && entries[index].Text != "" {
				answer.Text += entries[index].Text
				break
			}
		}
	}
	answer.Report = e.reportSince(thread, message)
	if contract := thread.Origin.Contract; contract != nil && len(contract.ResultSchema) > 0 && len(answer.Report) == 0 {
		answer.Reported = false
	}
	return answer
}

// needsInputReactor tells a spawner its child asks the user something, when
// its contract wakes on that and no wait of the spawner watches the child.
func (e *Engine) needsInputReactor(s *step, thread *threadState) {
	contract := thread.Origin.Contract
	if contract == nil || contract.Wake != WakeNeedsInput || len(thread.requests) == 0 || e.watched(thread.ID) {
		return
	}
	parent := e.threads[thread.Origin.Parent]
	if parent == nil || e.participants[thread.Origin.By] == nil {
		return
	}
	for _, request := range thread.requests {
		if e.noticed[request.ID] {
			continue
		}
		e.noticed[request.ID] = true
		notice := &Delivery{
			ID: DeliveryID(newID()), Thread: parent.ID, To: thread.Origin.By, From: daemon, Kind: KindNotice, Mode: ModeSteer,
			Body:  MessageBody{Text: "“" + thread.Title + "” (thread " + string(thread.ID) + ") asks the user: " + request.Ask.Message},
			State: DeliveryQueued, Position: e.nextPosition(parent), CreatedAt: s.now,
		}
		if thread.latest != nil {
			notice.Hops = thread.latest.Hops
		}
		parent.queue = append(parent.queue, notice)
		s.putDelivery(notice)
		e.notifyDelivery(s, parent, notice)
	}
}

// recover settles what a crash left running and probes what it left
// sending, then lets every reactor run.
func (e *Engine) recover(s *step) {
	for _, thread := range e.threads {
		if running := thread.runningTurn(); running != nil {
			// Its entries stay as flushed; the session's history fills in the
			// rest when the chat opens.
			running.State, running.Error, running.SettledAt = provider.TurnInterrupted, "maiD stopped while this turn ran.", s.now
			s.putTurn(running)
			if participant := e.participants[running.Participant]; participant != nil {
				participant.SeenThrough = running.ID
				s.putParticipant(participant)
			}
			// What was queued behind it waits for a person, as after a failure.
			if len(thread.queued()) > 0 && thread.Hold == HoldNone {
				thread.Hold = HoldFailed
				s.putThread(thread)
			}
		}
		for _, delivery := range slices.Clone(thread.queue) {
			if delivery.State != DeliverySending {
				continue
			}
			participant := e.participants[delivery.To]
			if participant == nil || participant.Session == "" {
				// It never reached a session.
				delivery.State = DeliveryQueued
				s.putDelivery(delivery)
				continue
			}
			e.probe(s, participant, delivery, "")
		}
		s.touch(thread.ID)
	}
}

// instanceHold keeps turns off an instance once nothing needs it.
type instanceHold struct {
	instance provider.InstanceID
	// granted closes when the hold takes effect, which active records.
	granted chan struct{}
	active  bool
}

// HoldInstance waits until nothing needs the instance, then keeps new turns from
// starting on it until release, so its processes can be replaced without cutting
// a turn off. Turns can still start while it waits, and a provider can start one
// of its own at any time.
func (e *Engine) HoldInstance(ctx context.Context, instance provider.InstanceID) (release func(), err error) {
	hold := &instanceHold{instance: instance, granted: make(chan struct{})}
	if !e.post(func(*step) { e.holds = append(e.holds, hold) }) {
		return nil, errClosed
	}
	release = func() { e.post(func(s *step) { e.endHold(s, hold) }) }
	select {
	case <-hold.granted:
		return release, nil
	case <-ctx.Done():
		release()
		return nil, ctx.Err()
	case <-e.done:
		return nil, errClosed
	}
}

func (e *Engine) instanceHeld(instance provider.InstanceID) bool {
	return slices.ContainsFunc(e.holds, func(hold *instanceHold) bool { return hold.active && hold.instance == instance })
}

// grantHolds runs after every step, since any step can leave an instance idle.
func (e *Engine) grantHolds() {
	for _, hold := range e.holds {
		if !hold.active && !e.instanceNeeded(hold.instance) {
			hold.active = true
			close(hold.granted)
		}
	}
}

// endHold lets what waited behind a hold start.
func (e *Engine) endHold(s *step, hold *instanceHold) {
	e.holds = slices.DeleteFunc(e.holds, func(other *instanceHold) bool { return other == hold })
	for id, thread := range e.threads {
		if len(thread.queued()) > 0 {
			s.touch(id)
		}
	}
}
