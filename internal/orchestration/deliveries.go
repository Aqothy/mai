package orchestration

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/Aqothy/maiD/internal/provider"
)

// startDelivery sends a queued delivery: as the thread's next turn, or with
// steer into the running one. sending is written before the provider call,
// so a crash leaves evidence; the participant's session opens first
// when it isn't live.
func (e *Engine) startDelivery(s *step, thread *threadState, delivery *Delivery, steer bool) {
	participant := e.participants[delivery.To]
	if participant == nil {
		e.refuse(s, thread, delivery, "The agent it was for is no longer in this chat.")
		return
	}
	delivery.State, delivery.Sent = DeliverySending, s.now
	if steer {
		delivery.Mode = ModeSteer
	} else if delivery.Mode == ModeSteer {
		delivery.Mode = ModeQueue
	}
	s.putDelivery(delivery)
	if e.sessionReady(thread, participant) {
		e.dispatch(s, thread, participant, delivery)
		return
	}
	e.openParticipant(s, thread, participant)
}

// sessionReady reports whether the participant's session takes Send now. A
// provider's own subagent is never opened: it lives in its parent's session.
func (e *Engine) sessionReady(thread *threadState, participant *participantState) bool {
	return participant.live != nil || thread.Origin.Kind == OriginNative && participant.Session != ""
}

// openParticipant opens the participant's session: resumed when it has one,
// otherwise new. Deliveries sending to it go once it is open.
func (e *Engine) openParticipant(s *step, thread *threadState, participant *participantState) {
	if participant.opening || participant.live != nil {
		return
	}
	participant.opening = true
	e.opening[participant.Instance]++
	info := e.instanceInfo(participant.Instance)
	in := provider.OpenInput{
		Session:   participant.Session,
		Workspace: thread.Workspace,
		Settings:  participant.Settings,
	}
	if e.cfg.MCP != nil {
		in.MCP = e.cfg.MCP(thread.ID, participant.ID)
	}
	if in.MCP != nil && info.Capabilities.Instructions {
		in.Instructions = e.cfg.Instructions
	}
	id := participant.ID
	s.providerCall(participant, func(ctx context.Context, instance provider.Instance, generation uint64) func(*step) {
		opened, err := instance.Open(ctx, in)
		return func(s *step) { e.opened(s, id, generation, opened, err) }
	}, func(s *step, err error) { e.opened(s, id, 0, provider.Opened{}, err) })
}

func (e *Engine) opened(s *step, id ParticipantID, generation uint64, opened provider.Opened, err error) {
	participant := e.participants[id]
	thread := e.threads[participant.Thread]
	participant.opening = false
	if e.opening[participant.Instance]--; e.opening[participant.Instance] <= 0 {
		delete(e.opening, participant.Instance)
	}
	// A session key names one chat, and the ledger enforces it. An agent breaking
	// ACP's unique session IDs costs this message, not the daemon.
	if owner, taken := e.bySession[sessionKey{participant.Instance, opened.Session}]; err == nil && taken && owner != id {
		err = errors.New("it gave this chat's session the ID of another chat's")
	}
	if err != nil {
		// A message that never reached the provider was not delivered.
		for _, delivery := range slices.Clone(thread.queue) {
			if delivery.To == id && delivery.State == DeliverySending && !e.dispatched[delivery.ID] {
				e.refuse(s, thread, delivery, "The agent couldn't start: "+err.Error())
			}
		}
		e.dropOrphans(participant.Instance)
		return
	}
	participant.live = &liveSession{generation: generation}
	if opened.Session != participant.Session {
		if participant.Session != "" {
			delete(e.bySession, sessionKey{participant.Instance, participant.Session})
			// A new session in place of one the provider couldn't resume has
			// none of the conversation: the next turn's handoff carries it.
			participant.SeenThrough = ""
		}
		participant.Session = opened.Session
		e.bySession[sessionKey{participant.Instance, participant.Session}] = participant.ID
		s.putParticipant(participant)
	}
	participant.options, participant.commands, participant.skills, participant.goal = opened.Options, opened.Commands, opened.Skills, opened.Goal
	e.notifyParticipant(s, thread, participant)
	e.replayOrphans(s, participant)
	for _, delivery := range slices.Clone(thread.queue) {
		if delivery.To == id && delivery.State == DeliverySending && !e.dispatched[delivery.ID] {
			e.dispatch(s, thread, participant, delivery)
		}
	}
}

// dispatch sends a delivery whose participant's session is open.
func (e *Engine) dispatch(s *step, thread *threadState, participant *participantState, delivery *Delivery) {
	steer := delivery.Mode == ModeSteer
	text, err := e.compose(thread, participant, delivery, steer)
	if err != nil {
		e.refuse(s, thread, delivery, err.Error())
		return
	}
	e.dispatched[delivery.ID] = true
	attachments := slices.Clone(delivery.Body.Attachments)
	in := provider.SendInput{Delivery: string(delivery.ID), Text: text, Steer: steer}
	id, session := delivery.ID, participant.Session
	store := e.attachments
	s.providerCall(participant, func(ctx context.Context, instance provider.Instance, generation uint64) func(*step) {
		withData, err := store.load(attachments)
		if err != nil {
			return func(s *step) { e.sendFailed(s, id, session, err, false) }
		}
		in.Attachments = withData
		ack, err := instance.Send(ctx, session, in)
		if err != nil {
			missed := errors.Is(err, provider.ErrTurnNotRunning)
			return func(s *step) { e.sendFailed(s, id, session, err, missed) }
		}
		return func(s *step) { e.acknowledged(s, id, ack) }
	}, func(s *step, err error) { e.sendFailed(s, id, session, err, false) })
}

// compose is the text a delivery sends the session: instructions for a
// provider that can't take them otherwise, conversation the session doesn't
// have yet, then the delivery's own.
func (e *Engine) compose(thread *threadState, participant *participantState, delivery *Delivery, steer bool) (string, error) {
	var envelopes []provider.Envelope
	if !steer {
		if !e.sessionHasTurns(participant) && e.cfg.Instructions != "" && e.cfg.MCP != nil && !e.instanceInfo(participant.Instance).Capabilities.Instructions && e.cfg.MCP(thread.ID, participant.ID) != nil {
			envelopes = append(envelopes, provider.Envelope{Kind: provider.EnvelopeInstructions, Body: e.cfg.Instructions})
		}
		handoff, err := e.handoff(thread, participant)
		if err != nil {
			return "", err
		}
		if handoff != nil {
			envelopes = append(envelopes, *handoff)
		}
	}
	switch delivery.Kind {
	case KindPrompt:
		return provider.ComposeMessage(envelopes, promptText(delivery.Body.Text, delivery.Body.Annotations)), nil
	case KindMessage:
		envelopes = append(envelopes, provider.Envelope{Kind: provider.EnvelopeMessage, Delivery: string(delivery.ID), From: e.senderName(delivery.From), Thread: string(delivery.From.Thread), Body: delivery.Body.Text})
	case KindReply:
		reply := provider.Envelope{Kind: provider.EnvelopeReply, Delivery: string(delivery.ID), From: e.senderName(delivery.From), Thread: string(delivery.From.Thread), Answers: string(delivery.Answers)}
		// Within one chat the handoff already carries the answer.
		if delivery.From.Thread != thread.ID {
			reply.Body = answerText(delivery.Answer)
		}
		envelopes = append(envelopes, reply)
	case KindNotice:
		envelopes = append(envelopes, provider.Envelope{Kind: provider.EnvelopeNotice, Delivery: string(delivery.ID), From: "maiD", Body: delivery.Body.Text})
	}
	return provider.ComposeMessage(envelopes, ""), nil
}

// quotesHeading starts a person's message that quotes the conversation.
const quotesHeading = "The user selected these passages from earlier in the chat as context:\n"

// promptText is a person's message as an agent reads it: the passages they
// quoted, each with their comment, then what they wrote.
func promptText(text string, annotations []provider.PromptAnnotation) string {
	var prompt strings.Builder
	quote := func(text string) {
		for _, line := range strings.Split(text, "\n") {
			prompt.WriteString("> " + line + "\n")
		}
	}
	selection := 0
	for _, annotation := range annotations {
		if strings.TrimSpace(annotation.Quote) == "" {
			continue
		}
		if selection == 0 {
			prompt.WriteString(quotesHeading)
		}
		selection++
		fmt.Fprintf(&prompt, "\nSelection %d", selection)
		if annotation.Role != "" {
			fmt.Fprintf(&prompt, " (%s)", annotation.Role)
		}
		prompt.WriteString(":\n")
		quote(annotation.Quote)
		if note := strings.TrimSpace(annotation.Note); note != "" {
			prompt.WriteString("Comment:\n")
			quote(note)
		}
	}
	if selection == 0 {
		return text
	}
	if text != "" {
		prompt.WriteString("\n" + text)
	}
	return prompt.String()
}

// withQuoteCards shows a person's message as they wrote it, with their
// quotes as cards: the session has the quotes inlined as text, the
// delivery that sent it keeps them as written.
func (e *Engine) withQuoteCards(entry *provider.Entry) {
	if entry.Kind != provider.ItemKindUserMessage || entry.Delivery == "" || !strings.HasPrefix(entry.Text, quotesHeading) {
		return
	}
	id := DeliveryID(entry.Delivery)
	var body MessageBody
	if _, queued := e.deliveryInQueue(id); queued != nil {
		body = queued.Body
	} else if stored, ok, err := e.db.delivery(e.ctx, id); err != nil {
		e.logger.Warn("read the delivery of a message", "delivery", id, "error", err)
		return
	} else if ok {
		body = stored.Body
	}
	if len(body.Annotations) > 0 {
		entry.Text, entry.Annotations = body.Text, body.Annotations
	}
}

// answerText is a reply's body: the answer, its state when it isn't a plain
// completion, and the structured report.
func answerText(answer *Answer) string {
	if answer == nil {
		return ""
	}
	var text strings.Builder
	if answer.State != provider.TurnCompleted && answer.State != "" {
		fmt.Fprintf(&text, "(The turn %s.)\n", answer.State)
	}
	text.WriteString(answer.Text)
	if len(answer.Report) > 0 {
		text.WriteString("\n\nReport:\n" + string(answer.Report))
	} else if !answer.Reported {
		text.WriteString("\n\n(No report was made.)")
	}
	return text.String()
}

// senderName names an actor for the agents it writes to: the agent and its
// chat.
func (e *Engine) senderName(actor Actor) string {
	switch actor.Kind {
	case ActorAgent:
		name := "An agent"
		if participant := e.participants[actor.Participant]; participant != nil {
			name = e.instanceName(participant.Instance)
		}
		if thread := e.threads[actor.Thread]; thread != nil && thread.Title != "" {
			return name + " · “" + thread.Title + "”"
		}
		return name
	case ActorDevice:
		return "The user"
	default:
		return "maiD"
	}
}

func (e *Engine) instanceName(id provider.InstanceID) string {
	if info, ok := e.cfg.Providers.Info(id); ok && info.Name != "" {
		return info.Name
	}
	return string(id)
}

// sessionHasTurns reports whether the participant's session has taken a
// turn of its thread; a new session, which the preamble opens, hasn't.
func (e *Engine) sessionHasTurns(participant *participantState) bool {
	thread := e.threads[participant.Thread]
	if latest := thread.latest; latest != nil && latest.Participant == participant.ID && latest.Session == participant.Session {
		return true
	}
	var exists bool
	if err := e.db.sql.QueryRowContext(e.ctx, `SELECT EXISTS(SELECT 1 FROM turns WHERE participant_id = ? AND native_session = ?)`, string(participant.ID), participant.Session).Scan(&exists); err != nil {
		e.logger.Warn("read a session's turns", "participant", participant.ID, "error", err)
	}
	return exists
}

// acknowledged: the provider took a delivery. Its turn row is made now, if
// TurnStarted didn't make it first.
func (e *Engine) acknowledged(s *step, id DeliveryID, ack provider.SendAck) {
	delete(e.dispatched, id)
	thread, delivery := e.deliveryInQueue(id)
	if delivery == nil || delivery.State != DeliverySending || ack.Turn == "" {
		// Without a turn, the session reads the message later (SendAck).
		return
	}
	e.delivered(s, thread, delivery, ack.Turn)
}

// delivered records a delivery the session took, with the turn it started or
// joined (ref).
func (e *Engine) delivered(s *step, thread *threadState, delivery *Delivery, ref string) {
	participant := e.participants[delivery.To]
	turn := e.turnFor(thread, participant, ref)
	if turn == nil {
		turn = &Turn{
			ID: TurnID(newID()), Thread: thread.ID, Participant: participant.ID, Session: participant.Session, Ref: ref,
			StartedBy: StartedByDelivery, ByAgent: delivery.From.Kind != ActorDevice, Hops: delivery.Hops,
			State: provider.TurnRunning, StartedAt: s.now,
		}
		e.beginTurn(s, thread, turn)
	}
	delivery.State, delivery.Turn, delivery.Reason = DeliveryDelivered, turn.ID, ""
	// The native session has the message now, with its quotes as text; the
	// cards they show as stay here.
	delivery.Body = MessageBody{Text: delivery.Body.Text, Annotations: delivery.Body.Annotations}
	if len(delivery.Body.Annotations) == 0 {
		delivery.Body = MessageBody{}
	}
	s.putDelivery(delivery)
	thread.dropFromQueue(delivery.ID)
	if delivery.Kind == KindMessage && delivery.WantsReply {
		thread.awaiting = append(thread.awaiting, delivery)
	}
	thread.UpdatedAt = s.now
	s.putThread(thread)
	e.notifyDelivery(s, thread, delivery)
}

// turnFor is the participant's turn with the ref: the running one, or one
// already recorded.
func (e *Engine) turnFor(thread *threadState, participant *participantState, ref string) *Turn {
	if running := thread.runningTurn(); running != nil && running.Ref == ref && running.Session == participant.Session {
		return running
	}
	if thread.latest != nil && thread.latest.Ref == ref && thread.latest.Session == participant.Session {
		return thread.latest
	}
	turn, ok, err := e.db.turnByRef(e.ctx, thread.ID, participant.Session, ref)
	if err != nil || !ok {
		return nil
	}
	return &turn
}

// beginTurn records a turn that started: the thread's latest.
func (e *Engine) beginTurn(s *step, thread *threadState, turn *Turn) {
	thread.latest = turn
	thread.entries = newLiveEntries(turn.ID)
	thread.interrupting = nil
	thread.plan = nil
	s.putTurn(turn)
	thread.UpdatedAt = s.now
	s.putThread(thread)
	e.notifyTurn(s, thread, turn)
}

// sendFailed: Send returned an error. A steer that missed its turn starts the
// next one. Otherwise the provider may still have taken it (its process died
// mid-call), so the session is asked; until then it stays sending.
func (e *Engine) sendFailed(s *step, id DeliveryID, session string, cause error, missed bool) {
	delete(e.dispatched, id)
	thread, delivery := e.deliveryInQueue(id)
	if delivery == nil || delivery.State != DeliverySending {
		return
	}
	if missed {
		delivery.State, delivery.Mode = DeliveryQueued, ModeQueue
		delivery.Position = e.frontPosition(thread)
		s.putDelivery(delivery)
		e.notifyDelivery(s, thread, delivery)
		return
	}
	participant := e.participants[delivery.To]
	if session == "" || participant == nil || participant.Session != session {
		e.refuse(s, thread, delivery, cause.Error())
		return
	}
	e.probe(s, participant, delivery, cause.Error())
}

// probe asks the session whether it took a delivery: yes delivers it,
// no refuses it with reason (or, after a crash, queues it again), unknown
// refuses it as maybe delivered.
func (e *Engine) probe(s *step, participant *participantState, delivery *Delivery, reason string) {
	probe := provider.DeliveryProbe{Delivery: string(delivery.ID), Text: delivery.Body.Text}
	id, session := delivery.ID, participant.Session
	s.providerCall(participant, func(ctx context.Context, instance provider.Instance, _ uint64) func(*step) {
		answer, err := instance.Delivered(ctx, session, probe)
		if err != nil {
			answer = provider.TriUnknown
		}
		return func(s *step) { e.probed(s, id, answer, reason) }
	}, func(s *step, _ error) { e.probed(s, id, provider.TriUnknown, reason) })
}

func (e *Engine) probed(s *step, id DeliveryID, answer provider.Tri, reason string) {
	thread, delivery := e.deliveryInQueue(id)
	if delivery == nil || delivery.State != DeliverySending {
		return
	}
	participant := e.participants[delivery.To]
	switch answer {
	case provider.TriYes:
		// Its turn comes from the session's history, whose user message
		// carries the delivery's ID; until then a placeholder ref stands in.
		e.delivered(s, thread, delivery, placeholderRef(delivery.ID))
		if participant.live == nil {
			// Its session isn't running, so neither is the turn: the
			// session's history has what happened.
			e.settleTurn(s, thread, thread.latest, provider.TurnSettled{State: provider.TurnInterrupted, Error: "maiD stopped while this turn ran."})
			e.reconcile(s, thread, participant)
		}
	case provider.TriNo:
		if reason == "" {
			// Found sending after a crash and never taken: it goes again.
			delivery.State = DeliveryQueued
			s.putDelivery(delivery)
			e.notifyDelivery(s, thread, delivery)
			return
		}
		e.refuse(s, thread, delivery, reason)
	default:
		e.refuse(s, thread, delivery, strings.TrimSuffix("It may not have been delivered. "+reason, " "))
	}
}

// refuse marks a delivery not delivered, with the reason shown beside Retry.
// Like a failed turn, it holds the queue, so nothing sent after it goes
// ahead of it unless someone says so.
func (e *Engine) refuse(s *step, thread *threadState, delivery *Delivery, reason string) {
	delete(e.dispatched, delivery.ID)
	delivery.State, delivery.Reason = DeliveryRefused, reason
	s.putDelivery(delivery)
	if thread.Hold == HoldNone {
		thread.Hold = HoldFailed
		s.putThread(thread)
	}
	e.notifyDelivery(s, thread, delivery)
}

func (e *Engine) deliveryInQueue(id DeliveryID) (*threadState, *Delivery) {
	for _, thread := range e.threads {
		if delivery := thread.queueDelivery(id); delivery != nil {
			return thread, delivery
		}
	}
	return nil, nil
}

func (e *Engine) nextPosition(thread *threadState) float64 {
	position := 0.0
	for _, delivery := range thread.queue {
		position = max(position, delivery.Position)
	}
	return position + 1
}

func (e *Engine) frontPosition(thread *threadState) float64 {
	position := 1.0
	for _, delivery := range thread.queue {
		position = min(position, delivery.Position)
	}
	return position - 1
}
