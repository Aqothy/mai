package orchestration

import (
	"slices"
	"strings"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// ProviderEvent takes an event of an instance's process generation. An
// entry's attachment data goes to the store here, off the engine.
func (e *Engine) ProviderEvent(instance provider.InstanceID, generation uint64, event provider.Event) {
	if upserted, ok := event.Body.(provider.EntryUpserted); ok {
		e.attachments.strip(&upserted.Entry)
		event.Body = upserted
	}
	e.post(func(s *step) { e.providerEvent(s, instance, generation, event) })
}

// InstanceGone: the instance's process of generation ended (exited, or was
// replaced). Its sessions are no longer live.
func (e *Engine) InstanceGone(instance provider.InstanceID, generation uint64) {
	e.post(func(s *step) {
		for _, participant := range e.participants {
			if participant.Instance == instance && participant.live != nil && participant.live.generation == generation {
				e.sessionClosed(s, participant, "The agent's process exited.")
			}
		}
	})
}

func placeholderRef(delivery DeliveryID) string { return "delivery:" + string(delivery) }

func (e *Engine) providerEvent(s *step, instance provider.InstanceID, generation uint64, event provider.Event) {
	if event.Session == "" {
		return
	}
	id, known := e.bySession[sessionKey{instance, event.Session}]
	if !known {
		if e.opening[instance] > 0 {
			e.orphans = append(e.orphans, orphanEvent{instance: instance, generation: generation, event: event})
		}
		return
	}
	participant := e.participants[id]
	if participant.live != nil && generation < participant.live.generation {
		// A replaced process's late events: only a settle still matters.
		if _, settles := event.Body.(provider.TurnSettled); !settles {
			return
		}
	}
	thread := e.threads[participant.Thread]
	at := event.At
	if at.IsZero() {
		at = s.now
	}
	switch body := event.Body.(type) {
	case provider.TurnStarted:
		e.turnStarted(s, thread, participant, body, at)
	case provider.TurnSettled:
		turn := e.turnFor(thread, participant, body.Turn)
		e.settleTurn(s, thread, turn, body)
	case provider.EntryUpserted:
		e.entryUpserted(s, thread, participant, body.Entry)
	case provider.TextAppended:
		if thread.entries != nil && thread.latest != nil && thread.latest.Ref == body.Turn && thread.latest.Session == participant.Session && thread.entries.append(body.Entry, body.Text) {
			e.notifyText(s, thread, body)
		}
	case provider.RequestOpened:
		e.requestOpened(s, thread, participant, body, at)
	case provider.RequestResolved:
		e.requestResolved(s, thread, body.Request, body.Action, body.Answers)
	case provider.ConfigChanged:
		if body.Options != nil {
			participant.options = body.Options
		}
		if body.Commands != nil {
			participant.commands = body.Commands
		}
		if body.Skills != nil {
			participant.skills = body.Skills
		}
		e.notifyParticipant(s, thread, participant)
	case provider.PlanChanged:
		thread.plan = body.Entries
		e.notifyPlan(s, thread)
	case provider.GoalChanged:
		participant.goal = body.Goal
		e.notifyParticipant(s, thread, participant)
	case provider.UsageChanged:
		usage := body.Usage
		participant.usage = &usage
		e.notifyParticipant(s, thread, participant)
	case provider.TitleChanged:
		if title := strings.TrimSpace(body.Title); title != "" && title != thread.Title {
			thread.Title = title
			s.putThread(thread)
		}
	case provider.SessionReplaced:
		e.sessionReplaced(s, thread, participant, body.New)
	case provider.SessionClosed:
		reason := "The agent's session ended."
		if body.Error != "" {
			reason = body.Error
		}
		e.sessionClosed(s, participant, reason)
	case provider.SubagentSeen:
		e.subagentSeen(s, thread, participant, body)
	case provider.Warning:
		e.warning(s, thread, participant, body, at)
	case provider.InstanceChanged:
	}
}

func (e *Engine) turnStarted(s *step, thread *threadState, participant *participantState, started provider.TurnStarted, at time.Time) {
	if started.Delivery != "" {
		owner, delivery := e.deliveryInQueue(DeliveryID(started.Delivery))
		if delivery != nil && owner == thread && delivery.State == DeliverySending {
			e.delivered(s, thread, delivery, started.Turn)
			return
		}
		// Delivered already (by its ack, or a probe with a placeholder ref).
		if running := thread.runningTurn(); running != nil && running.Ref == placeholderRef(DeliveryID(started.Delivery)) {
			running.Ref = started.Turn
			s.putTurn(running)
			return
		}
		if e.turnFor(thread, participant, started.Turn) != nil {
			return
		}
		// A message maiD doesn't know (sent before the thread was maiD's)
		// starts a turn like the provider's own.
	}
	if running := thread.runningTurn(); running != nil {
		if running.Ref == started.Turn {
			return
		}
		// The provider moved on without settling the turn it ran.
		e.settleTurn(s, thread, running, provider.TurnSettled{Turn: running.Ref, State: provider.TurnInterrupted})
	}
	if e.turnFor(thread, participant, started.Turn) != nil {
		return
	}
	hops := 0
	if thread.latest != nil && thread.latest.Participant == participant.ID {
		hops = thread.latest.Hops
	}
	e.beginTurn(s, thread, &Turn{
		ID: TurnID(newID()), Thread: thread.ID, Participant: participant.ID, Session: participant.Session, Ref: started.Turn,
		StartedBy: StartedByProvider, Hops: hops, State: provider.TurnRunning, StartedAt: at,
	})
}

// settleTurn ends a turn: its entries are written with the settle, its open
// requests end, and its participant has seen the thread through it.
func (e *Engine) settleTurn(s *step, thread *threadState, turn *Turn, settled provider.TurnSettled) {
	if turn == nil || turn.State != provider.TurnRunning {
		return
	}
	participant := e.participants[turn.Participant]
	turn.State, turn.StopReason, turn.Error, turn.SettledAt = settled.State, settled.StopReason, settled.Error, s.now
	if turn.State == "" {
		turn.State = provider.TurnCompleted
	}
	s.putTurn(turn)
	if thread.entries != nil && thread.entries.turn == turn.ID {
		e.flushEntries(s, thread, participant, false)
		thread.entries = nil
	}
	for _, request := range thread.requests {
		if request.Turn == turn.ID {
			e.requestResolved(s, thread, request.ID, "", nil)
		}
	}
	if participant != nil {
		participant.SeenThrough = turn.ID
		s.putParticipant(participant)
		// The cache has the session through this turn.
		if info, ok := e.cfg.Providers.Info(participant.Instance); ok && turn.Session == participant.Session && !strings.HasPrefix(turn.Ref, placeholderRef("")) {
			s.tx.markers[sessionKey{participant.Instance, turn.Session}] = marker{marker: provider.Marker(turn.Ref), version: info.Capabilities.HistoryVersion}
		}
	}
	// Replies its agent's wait or read took reached it with the turn.
	for _, delivery := range slices.Clone(thread.queue) {
		if delivery.Kind == KindReply && delivery.State == DeliverySending && delivery.Turn == turn.ID && !e.dispatched[delivery.ID] {
			delivery.State = DeliveryDelivered
			s.putDelivery(delivery)
			thread.dropFromQueue(delivery.ID)
		}
	}
	// A turn that didn't complete holds what waits behind it: whoever
	// stopped it, or, when it failed or was cut off, a person or an agent
	// above decides what goes next. A message that released the stop goes next.
	if queued := thread.queued(); len(queued) > 0 && thread.Hold == HoldNone && turn.State != provider.TurnCompleted {
		switch {
		case thread.interrupting == nil:
			thread.Hold = HoldFailed
		case thread.interrupting.released:
		case thread.interrupting.by.Kind == ActorAgent:
			thread.Hold = HoldStoppedAgent
		default:
			thread.Hold = HoldStoppedPerson
		}
	}
	thread.interrupting = nil
	thread.UpdatedAt = s.now
	s.putThread(thread)
	e.notifyTurn(s, thread, turn)
	e.wakeWaits(s)
}

// entryUpserted keeps a running turn's entry in memory until its settle; an
// entry of a settled turn (a background task finishing after it) is written
// now.
func (e *Engine) entryUpserted(s *step, thread *threadState, participant *participantState, entry provider.Entry) {
	e.withQuoteCards(&entry)
	// A message the session read later than its Send names its turn here.
	if entry.Delivery != "" {
		if owner, delivery := e.deliveryInQueue(DeliveryID(entry.Delivery)); owner == thread && delivery != nil && delivery.State == DeliverySending {
			e.delivered(s, thread, delivery, entry.Turn)
		}
	}
	if thread.entries != nil && thread.latest != nil && thread.latest.Ref == entry.Turn && thread.latest.Session == participant.Session {
		thread.entries.upsert(entry)
		e.notifyEntry(s, thread, thread.latest, entry)
		return
	}
	turn := e.turnFor(thread, participant, entry.Turn)
	if turn == nil {
		e.logger.Debug("dropping entry of an unknown turn", "thread", thread.ID, "turn", entry.Turn, "entry", entry.Ref)
		return
	}
	s.putEntries(participant.Instance, participant.Session, authoredByProvider, entry)
	e.notifyEntry(s, thread, turn, entry)
}

// flushRunning writes the running turns' changed entries.
func (e *Engine) flushRunning(s *step) {
	for _, thread := range e.threads {
		if thread.entries == nil || len(thread.entries.dirty) == 0 {
			continue
		}
		if participant := e.participants[thread.latest.Participant]; participant != nil {
			e.flushEntries(s, thread, participant, true)
		}
	}
}

func (e *Engine) flushEntries(s *step, thread *threadState, participant *participantState, onlyDirty bool) {
	live := thread.entries
	for _, ref := range live.order {
		if onlyDirty && !live.dirty[ref] {
			continue
		}
		s.putEntries(participant.Instance, participant.Session, authoredByProvider, *live.byRef[ref])
	}
	clear(live.dirty)
}

func (e *Engine) requestOpened(s *step, thread *threadState, participant *participantState, opened provider.RequestOpened, at time.Time) {
	request := &pendingRequest{ID: opened.Request, Participant: participant.ID, Entry: opened.Entry, Ask: opened.Ask, OpenedAt: at}
	if turn := e.turnFor(thread, participant, opened.Turn); turn != nil {
		request.Turn = turn.ID
	} else if running := thread.runningTurn(); running != nil && running.Participant == participant.ID {
		request.Turn = running.ID
	}
	thread.requests[request.ID] = request
	s.touch(thread.ID)
	e.notifyRequest(s, thread, request, nil)
	e.wakeWaits(s)
}

// requestResolved ends a request: it leaves the thread, and a record of what
// was asked and answered joins the conversation, since providers keep
// neither.
func (e *Engine) requestResolved(s *step, thread *threadState, id, action string, answers map[string][]string) {
	request := thread.requests[id]
	if request == nil {
		return
	}
	delete(thread.requests, id)
	s.touch(thread.ID)
	record := &provider.RequestRecord{Request: id, Ask: request.Ask, Action: action, Answers: answers}
	if participant := e.participants[request.Participant]; participant != nil {
		if turn := e.requestTurn(thread, request); turn != nil {
			entry := provider.Entry{Ref: "request:" + id, Turn: turn.Ref, Kind: provider.ItemKindRequest, Status: provider.ItemStatusCompleted, Request: record, At: s.now}
			if thread.entries != nil && thread.entries.turn == turn.ID {
				thread.entries.upsert(entry)
			} else {
				s.putEntries(participant.Instance, turn.Session, authoredByMaid, entry)
			}
			e.notifyEntry(s, thread, turn, entry)
		}
	}
	e.notifyRequest(s, thread, request, record)
}

func (e *Engine) requestTurn(thread *threadState, request *pendingRequest) *Turn {
	if request.Turn == "" {
		return nil
	}
	if thread.latest != nil && thread.latest.ID == request.Turn {
		return thread.latest
	}
	turn, ok, err := e.db.turn(e.ctx, request.Turn)
	if err != nil || !ok {
		return nil
	}
	return &turn
}

func (e *Engine) warning(s *step, thread *threadState, participant *participantState, warning provider.Warning, at time.Time) {
	turn := e.turnFor(thread, participant, warning.Turn)
	if turn == nil && thread.latest != nil && thread.latest.Participant == participant.ID {
		turn = thread.latest
	}
	if turn == nil {
		e.logger.Info("provider warning outside a turn", "thread", thread.ID, "message", warning.Message)
		return
	}
	entry := provider.Entry{Ref: "warning:" + newID(), Turn: turn.Ref, Kind: provider.ItemKindWarning, Status: provider.ItemStatusCompleted, Text: warning.Message, At: at}
	if thread.entries != nil && thread.entries.turn == turn.ID {
		thread.entries.upsert(entry)
	} else {
		s.putEntries(participant.Instance, turn.Session, authoredByMaid, entry)
	}
	e.notifyEntry(s, thread, turn, entry)
}

// sessionReplaced moves the participant to the session its conversation
// continues in. The user cleared the agent's context on purpose, so no
// handoff brings it back: it has seen the thread through its last turn.
func (e *Engine) sessionReplaced(s *step, thread *threadState, participant *participantState, session string) {
	if session == "" || session == participant.Session {
		return
	}
	delete(e.bySession, sessionKey{participant.Instance, participant.Session})
	participant.Session = session
	e.bySession[sessionKey{participant.Instance, session}] = participant.ID
	if thread.latest != nil {
		participant.SeenThrough = thread.latest.ID
	}
	s.putParticipant(participant)
}

// sessionClosed: the participant's live session ended. A turn it ran ends
// with it, and its requests can no longer be answered.
func (e *Engine) sessionClosed(s *step, participant *participantState, reason string) {
	participant.live = nil
	thread := e.threads[participant.Thread]
	if running := thread.runningTurn(); running != nil && running.Participant == participant.ID {
		e.settleTurn(s, thread, running, provider.TurnSettled{Turn: running.Ref, State: provider.TurnFailed, Error: reason})
	}
	for _, request := range thread.requests {
		if request.Participant == participant.ID {
			e.requestResolved(s, thread, request.ID, "", nil)
		}
	}
	// Messages the session took but hadn't read yet may be lost with it.
	for _, delivery := range slices.Clone(thread.queue) {
		if delivery.To == participant.ID && delivery.State == DeliverySending && !e.dispatched[delivery.ID] {
			e.probe(s, participant, delivery, "The agent's session ended before it read this message.")
		}
	}
	e.notifyParticipant(s, thread, participant)
}

func (e *Engine) replayOrphans(s *step, participant *participantState) {
	var kept []orphanEvent
	for _, orphan := range e.orphans {
		if orphan.instance == participant.Instance && orphan.event.Session == participant.Session {
			e.providerEvent(s, orphan.instance, orphan.generation, orphan.event)
			continue
		}
		kept = append(kept, orphan)
	}
	e.orphans = kept
	e.dropOrphans(participant.Instance)
}

// dropOrphans forgets an instance's orphans once none of its Opens is in
// flight: no session they could belong to is coming.
func (e *Engine) dropOrphans(instance provider.InstanceID) {
	if e.opening[instance] > 0 {
		return
	}
	e.orphans = slices.DeleteFunc(e.orphans, func(orphan orphanEvent) bool { return orphan.instance == instance })
}
