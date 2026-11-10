package orchestration

import (
	"context"
	"fmt"
	"slices"
	"strings"

	"github.com/Aqothy/maiD/internal/provider"
)

// A fork continues a thread through a turn in a new thread, with
// one agent. Where it continues with the chat's own agent and that agent's
// provider can fork, its session forks natively: the exact conversation,
// which the new session's history shows. Otherwise the agent starts a session
// of its own and gets the conversation as text in its first message: for a
// person's fork, a summary they saw and could edit first (ForkPreview); for
// an agent's consult, added to the brief. The provider call runs first; the
// fork commits in one step once it is done, so the ledger never holds half a
// fork, and a crash in between leaves at most an unused native session.

// forkSource is what a fork continues.
type forkSource struct {
	thread *threadState
	// through is the last kept turn; empty when it keeps none.
	through TurnID
	kept    []Turn
	// inProgress is a running turn's content so far, for a consult of a
	// thread that runs: what the source is in the middle of.
	inProgress string
}

// forkJob is a native fork waiting for its provider call.
type forkJob struct {
	source  forkSource
	carryOn *participantState
	session string
	history []provider.HistoryTurn
	// finish makes the new thread once the call came back.
	finish func(s *step, job *forkJob) (CommandResult, error)
	reply  chan asyncOutcome
	key    string
	actor  Actor
}

func (e *Engine) forkSourceOf(thread *threadState, through TurnID) (forkSource, error) {
	turns, err := e.db.threadTurns(e.ctx, thread.ID, nil, 0)
	if err != nil {
		return forkSource{}, err
	}
	source := forkSource{thread: thread}
	for _, turn := range turns {
		if turn.State == provider.TurnRunning {
			continue
		}
		source.kept = append(source.kept, turn)
		source.through = turn.ID
		if turn.ID == through {
			break
		}
	}
	if through != "" && source.through != through {
		return forkSource{}, refused(CodeNotFound, "turn %q isn't a settled turn of the chat", through)
	}
	return source, nil
}

// nativeAgent is the participant whose session forks natively through the
// source's kept turns, if any: the one that took the last of them, in its
// current session, which saw everything before it, where its provider can
// fork.
func (e *Engine) nativeAgent(source forkSource) *participantState {
	if len(source.kept) == 0 {
		return nil
	}
	last := source.kept[len(source.kept)-1]
	participant := e.participants[last.Participant]
	if participant == nil || last.Session != participant.Session || strings.HasPrefix(last.Ref, placeholderRef("")) || !e.instanceInfo(participant.Instance).Capabilities.Fork {
		return nil
	}
	return participant
}

// ForkPreview is what a fork through a turn starts from: its agent's
// session forked natively, or, with Summary, a new session whose first
// message carries the conversation, for the person to edit before sending.
type ForkPreview struct {
	Native  bool   `json:"native"`
	Summary string `json:"summary,omitempty"`
}

// forkSummaryHeading starts the summary a fork's first message carries.
const forkSummaryHeading = "Here is the conversation so far, from the chat this one continues:\n\n"

// ForkPreview tells a client how a fork of the thread through a turn would
// start, with the chat's own agent or, when agent names one, another.
func (e *Engine) ForkPreview(ctx context.Context, id ThreadID, through TurnID, agent provider.InstanceID) (ForkPreview, error) {
	return call(ctx, e, func(s *step) (ForkPreview, error) {
		thread, err := e.existing(id)
		if err != nil {
			return ForkPreview{}, err
		}
		source, err := e.forkSourceOf(thread, through)
		if err != nil {
			return ForkPreview{}, err
		}
		if agent == "" && e.nativeAgent(source) != nil {
			return ForkPreview{Native: true}, nil
		}
		if len(source.kept) == 0 {
			return ForkPreview{}, nil
		}
		text, err := e.transcript(source.kept, handoffBudget)
		if err != nil {
			return ForkPreview{}, err
		}
		return ForkPreview{Summary: forkSummaryHeading + text + "\n\n"}, nil
	})
}

// startFork forks carryOn's session natively, then finishes; without
// carryOn it finishes at once.
func (e *Engine) startFork(s *step, command Command, source forkSource, carryOn *participantState, finish func(*step, *forkJob) (CommandResult, error)) (CommandResult, chan asyncOutcome, error) {
	job := &forkJob{source: source, carryOn: carryOn, finish: finish, reply: make(chan asyncOutcome, 1), key: command.Key, actor: command.Actor}
	if carryOn == nil {
		result, err := finish(s, job)
		return result, nil, err
	}
	in := provider.ForkInput{Session: carryOn.Session, Through: source.kept[len(source.kept)-1].Ref, Workspace: source.thread.Workspace, Settings: carryOn.Settings}
	s.providerCall(carryOn, func(ctx context.Context, instance provider.Instance, _ uint64) func(*step) {
		session, err := instance.Fork(ctx, in)
		var history []provider.HistoryTurn
		if err == nil {
			var page provider.HistoryPage
			if page, err = instance.History(ctx, session, in.Workspace, ""); err == nil {
				history = page.Turns
				e.attachments.stripTurns(history)
			}
		}
		return func(s *step) { e.forkCallDone(s, job, session, history, err) }
	}, func(s *step, err error) { e.forkCallDone(s, job, "", nil, err) })
	return CommandResult{}, job.reply, nil
}

func (e *Engine) forkCallDone(s *step, job *forkJob, session string, history []provider.HistoryTurn, err error) {
	if err != nil {
		// Nothing was made; the person tries again, or continues in
		// another agent.
		job.reply <- asyncOutcome{err: refused(CodeAgentUnavailable, "the agent couldn't fork its session: %v", err)}
		return
	}
	if e.threads[job.source.thread.ID] == nil {
		job.reply <- asyncOutcome{err: refused(CodeNotFound, "the chat was deleted while it forked")}
		return
	}
	job.session, job.history = session, history
	result, err := job.finish(s, job)
	if err == nil && job.key != "" {
		s.tx.receipts = append(s.tx.receipts, receiptRow{actor: job.actor, key: job.key, result: mustJSON(result)})
	}
	s.after(func() { job.reply <- asyncOutcome{result: result, err: err} })
}

// forkedParticipant adds the native fork's participant to thread, with its
// new session and the turns its history shows, at their source turns'
// times; its session saw the chat through its last turn.
func (e *Engine) forkedParticipant(s *step, thread *threadState, job *forkJob) *participantState {
	carryOn := job.carryOn
	participant := e.newParticipant(s, thread, NewParticipant{Instance: carryOn.Instance, Settings: carryOn.Settings})
	participant.Session = job.session
	e.bySession[sessionKey{participant.Instance, participant.Session}] = participant.ID
	var kept []Turn
	for _, turn := range job.source.kept {
		if turn.Participant == carryOn.ID {
			kept = append(kept, turn)
		}
	}
	for index, native := range job.history {
		startedAt := native.StartedAt
		if index < len(kept) {
			startedAt = kept[index].StartedAt
		}
		if startedAt.IsZero() {
			startedAt = s.now
		}
		for entry := range native.Entries {
			e.withQuoteCards(&native.Entries[entry])
		}
		turn := &Turn{
			ID: TurnID(newID()), Thread: thread.ID, Participant: participant.ID, Session: participant.Session, Ref: native.Ref,
			StartedBy: StartedByFound, State: native.State, StopReason: native.StopReason, Error: native.Error, StartedAt: startedAt, SettledAt: s.now,
		}
		if !turn.State.Settled() {
			turn.State = provider.TurnInterrupted
		}
		e.putKnownTurn(s, thread, turn)
		s.putEntries(participant.Instance, participant.Session, authoredByProvider, native.Entries...)
		participant.SeenThrough = turn.ID
	}
	s.putParticipant(participant)
	s.tx.markers[sessionKey{participant.Instance, participant.Session}] = marker{marker: lastRef(job.history), version: e.instanceInfo(participant.Instance).Capabilities.HistoryVersion}
	return participant
}

func lastRef(turns []provider.HistoryTurn) provider.Marker {
	if len(turns) == 0 {
		return ""
	}
	return provider.Marker(turns[len(turns)-1].Ref)
}

func (e *Engine) forkThread(s *step, command Command, fork ForkThread) (CommandResult, chan asyncOutcome, error) {
	if err := e.requireDevice(command.Actor, "fork a chat"); err != nil {
		return CommandResult{}, nil, err
	}
	source, err := e.existing(fork.Thread)
	if err != nil {
		return CommandResult{}, nil, err
	}
	plan, err := e.forkSourceOf(source, fork.Through)
	if err != nil {
		return CommandResult{}, nil, err
	}
	// Checked before the native fork, so a refused fork leaves nothing.
	var carryOn *participantState
	if fork.Agent == nil {
		if carryOn = e.nativeAgent(plan); carryOn == nil {
			return CommandResult{}, nil, refused(CodeInvalid, "this chat's agent can't fork its session here; continue in an agent with the conversation instead")
		}
	} else if err := e.validateParticipant(*fork.Agent, source.Workspace); err != nil {
		return CommandResult{}, nil, err
	}
	if err := e.checkPrompt(fork.Prompt); err != nil {
		return CommandResult{}, nil, err
	}
	return e.startFork(s, command, plan, carryOn, func(s *step, job *forkJob) (CommandResult, error) {
		thread := e.newThread(s, source.Title+" (fork)", source.Workspace, Origin{Kind: OriginUser, ForkedFrom: &ForkPoint{Thread: source.ID, Turn: plan.through}})
		var agent *participantState
		if carryOn != nil {
			agent = e.forkedParticipant(s, thread, job)
		} else {
			agent = e.newParticipant(s, thread, *fork.Agent)
		}
		thread.Address = agent.ID
		s.putThread(thread)
		return e.deliver(s, command.Actor, Deliver{Thread: thread.ID, Body: fork.Prompt, Mode: ModeQueue})
	})
}

// spawn starts a child thread on a brief: a message from the caller
// that always wants a reply, the child's result.
func (e *Engine) spawn(s *step, command Command, spawn Spawn) (CommandResult, chan asyncOutcome, error) {
	actor := command.Actor
	parent, err := e.existing(spawn.Parent)
	if err != nil {
		return CommandResult{}, nil, err
	}
	by := parent.Address
	switch actor.Kind {
	case ActorAgent:
		if actor.Thread != parent.ID {
			return CommandResult{}, nil, refused(CodeOutOfScope, "an agent spawns only under its own chat")
		}
		by = actor.Participant
	case ActorDevice:
	default:
		return CommandResult{}, nil, refused(CodeOutOfScope, "the daemon doesn't spawn")
	}
	spawner := e.participants[by]
	if spawner == nil {
		return CommandResult{}, nil, refused(CodeNotFound, "the spawning agent isn't in the chat")
	}
	if e.depth(parent)+1 > e.policy(parent).MaxDepth {
		return CommandResult{}, nil, refused(CodeDepthExceeded, "chats may go only %d levels below their root", e.policy(parent).MaxDepth)
	}
	if spawn.Brief == "" {
		return CommandResult{}, nil, refused(CodeInvalid, "a spawn needs a brief")
	}
	agent := spawn.Agent
	// A consult forks a thread the caller may read; "fork" is its own. Its
	// agent defaults to the one that took the source's last turn, which then
	// carries on as its native fork where it can.
	var plan *forkSource
	var carryOn *participantState
	if spawn.Context != nil {
		sourceID := spawn.Context.Thread
		if sourceID == "" {
			sourceID = parent.ID
		}
		sourceThread, err := e.existing(sourceID)
		if err != nil {
			return CommandResult{}, nil, err
		}
		if actor.Kind == ActorAgent && !e.mayRead(actor, sourceThread) {
			return CommandResult{}, nil, refused(CodeOutOfScope, "you can't read chat %q", sourceID)
		}
		source, err := e.forkSourceOf(sourceThread, spawn.Context.Turn)
		if err != nil {
			return CommandResult{}, nil, err
		}
		if running := sourceThread.runningTurn(); running != nil && sourceThread.entries != nil {
			if participant := e.participants[running.Participant]; participant != nil {
				source.inProgress = turnText(e.instanceName(participant.Instance), *running, sourceThread.entries.list())
			}
		}
		plan = &source
		if len(source.kept) > 0 {
			if last := e.participants[source.kept[len(source.kept)-1].Participant]; last != nil && agent.Instance == "" {
				agent.Instance = last.Instance
			}
		}
		if native := e.nativeAgent(source); native != nil && native.Instance == agent.Instance {
			carryOn = native
		}
	}
	if agent.Instance == "" {
		agent.Instance = spawner.Instance
	}
	if err := e.validateParticipant(agent, parent.Workspace); err != nil {
		return CommandResult{}, nil, err
	}
	info := e.instanceInfo(agent.Instance)
	ceiling := e.accessLevel(spawner).Ceiling()
	level := ceiling
	if spawn.Access != nil {
		if !spawn.Access.Known() || *spawn.Access == provider.AccessUnknown {
			return CommandResult{}, nil, refused(CodeInvalid, "unknown access level %q", *spawn.Access)
		}
		level = *spawn.Access
	}
	if actor.Kind == ActorAgent && level.Ceiling().Exceeds(ceiling) {
		return CommandResult{}, nil, refused(CodeCeilingExceeded, "a child can't have more access than you")
	}
	settings, err := withAccess(info, agent.Settings, level)
	if err != nil {
		if actor.Kind == ActorAgent && ceiling < provider.AccessFull {
			return CommandResult{}, nil, refused(CodeCeilingExceeded, "%s's access modes aren't mapped, so it counts as full access; map them in its settings", info.Name)
		}
		settings = agent.Settings
	}
	agent.Settings = settings
	wake := spawn.Wake
	if wake == "" {
		wake = WakeSettled
	}
	contract := &Contract{Brief: spawn.Brief, ResultSchema: spawn.ResultSchema, Wake: wake, Access: level}
	title := spawn.Title
	if title == "" {
		title = provider.PromptPreviewTitle(spawn.Brief)
		if runes := []rune(title); len(runes) > 80 {
			title = string(runes[:80])
		}
	}
	makeChild := func(s *step, job *forkJob) (CommandResult, error) {
		origin := Origin{Kind: OriginSpawn, Parent: parent.ID, By: by, At: e.runningToolEntry(parent, by), Contract: contract}
		if job != nil {
			origin.ForkedFrom = &ForkPoint{Thread: job.source.thread.ID, Turn: job.source.through}
		}
		child := e.newThread(s, title, parent.Workspace, origin)
		var participant *participantState
		// A consult's brief carries what its session doesn't have: the
		// conversation, unless the agent forked natively, and a turn the
		// source is in the middle of.
		var context strings.Builder
		switch {
		case job != nil && job.carryOn != nil:
			// A consult of the same agent is its native fork, with the
			// child's settings and access.
			participant = e.forkedParticipant(s, child, job)
			participant.Settings = agent.Settings
			s.putParticipant(participant)
		case job != nil && len(job.source.kept) > 0:
			conversation, err := e.transcript(job.source.kept, handoffBudget)
			if err != nil {
				return CommandResult{}, err
			}
			context.WriteString(forkSummaryHeading + conversation + "\n\n")
		}
		if job != nil && job.source.inProgress != "" {
			context.WriteString("[In progress in that chat when this started:]\n" + job.source.inProgress + "\n\n")
		}
		text := context.String() + spawn.Brief
		if participant == nil {
			participant = e.newParticipant(s, child, agent)
		}
		child.Address = participant.ID
		s.putThread(child)
		brief := &Delivery{
			ID: DeliveryID(newID()), Thread: child.ID, To: participant.ID, From: actor, Mode: ModeQueue,
			Body: MessageBody{Text: text}, State: DeliveryQueued, Position: 1, CreatedAt: s.now,
		}
		if actor.Kind == ActorAgent {
			// Delegation keeps the spawner's hops: depth and concurrency bound
			// it, not the hop limit.
			brief.Kind, brief.WantsReply, brief.Hops = KindMessage, true, e.actorHops(actor)
		} else {
			brief.Kind = KindPrompt
		}
		child.queue = append(child.queue, brief)
		s.putDelivery(brief)
		e.notifyDelivery(s, child, brief)
		return CommandResult{Thread: child.ID, Participant: participant.ID, Delivery: brief.ID}, nil
	}
	if plan == nil {
		result, err := makeChild(s, nil)
		return result, nil, err
	}
	return e.startFork(s, command, *plan, carryOn, makeChild)
}

// runningToolEntry is the tool entry of the spawner's running turn that a
// child came from: its last tool call.
func (e *Engine) runningToolEntry(thread *threadState, by ParticipantID) string {
	running := thread.runningTurn()
	if running == nil || running.Participant != by || thread.entries == nil {
		return ""
	}
	entries := thread.entries.list()
	for index := len(entries) - 1; index >= 0; index-- {
		if entries[index].Tool != nil {
			return entries[index].Ref
		}
	}
	return ""
}

// withAccess sets the instance's access option to the mode for level: the
// most permissive one that doesn't exceed it.
func withAccess(info provider.InstanceInfo, settings []provider.ConfigOptionSelection, level provider.AccessLevel) ([]provider.ConfigOptionSelection, error) {
	if info.Access == nil {
		return nil, fmt.Errorf("%s has no access modes", info.Name)
	}
	best, bestLevel := "", provider.AccessUnknown
	for value, candidate := range info.Access.Levels {
		if !candidate.Exceeds(level) && (candidate.Exceeds(bestLevel) || candidate == bestLevel && value < best) {
			best, bestLevel = value, candidate
		}
	}
	if best == "" {
		return nil, fmt.Errorf("%s has no mode within that access", info.Name)
	}
	out := slices.DeleteFunc(slices.Clone(settings), func(setting provider.ConfigOptionSelection) bool { return setting.OptionID == info.Access.Option })
	return append(out, provider.ConfigOptionSelection{OptionID: info.Access.Option, Value: best, Category: provider.ConfigOptionCategoryMode}), nil
}
