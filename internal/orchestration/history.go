package orchestration

import (
	"context"
	"slices"

	"github.com/Aqothy/maiD/internal/provider"
)

// catchUp reads the history of a thread's sessions that aren't live, so
// turns run in the CLI meanwhile show and entries cached by another adapter
// version are rebuilt, and returns a channel closed once no read of them is
// in flight.
func (e *Engine) catchUp(s *step, thread *threadState) chan struct{} {
	for _, id := range thread.participants {
		participant := e.participants[id]
		if participant.live == nil && participant.Session != "" {
			e.reconcile(s, thread, participant)
		}
	}
	done := make(chan struct{})
	if e.readingHistory(thread) {
		thread.caughtUp = append(thread.caughtUp, done)
	} else {
		close(done)
	}
	return done
}

func (e *Engine) readingHistory(thread *threadState) bool {
	return slices.ContainsFunc(thread.participants, func(id ParticipantID) bool { return e.participants[id].reconciling })
}

// reconcile reads the participant's session history after the cache's
// marker; a marker of another adapter version reads it all and rebuilds the
// session's entries.
func (e *Engine) reconcile(s *step, thread *threadState, participant *participantState) {
	if participant.reconciling || participant.Session == "" {
		return
	}
	stored, err := e.db.marker(e.ctx, participant.Instance, participant.Session)
	if err != nil {
		e.logger.Warn("read session marker", "error", err)
		return
	}
	participant.reconciling = true
	id, session, workspace := participant.ID, participant.Session, thread.Workspace
	s.providerCall(participant, func(ctx context.Context, instance provider.Instance, _ uint64) func(*step) {
		version := instance.Info().Capabilities.HistoryVersion
		rebuild := stored.marker != "" && stored.version != version
		after := stored.marker
		if rebuild {
			after = ""
		}
		page, err := instance.History(ctx, session, workspace, after)
		// A rebuild needs every turn, not a page of them.
		for err == nil && page.More {
			var next provider.HistoryPage
			next, err = instance.History(ctx, session, workspace, page.Next)
			page.Turns, page.Subagents, page.Next, page.More = append(page.Turns, next.Turns...), append(page.Subagents, next.Subagents...), next.Next, next.More
		}
		e.attachments.stripTurns(page.Turns)
		return func(s *step) { e.applyHistory(s, id, session, page, err, rebuild || page.Reset, version) }
	}, func(s *step, err error) { e.applyHistory(s, id, session, provider.HistoryPage{}, err, false, 0) })
}

func (e *Engine) applyHistory(s *step, id ParticipantID, session string, page provider.HistoryPage, err error, rebuild bool, version int) {
	participant := e.participants[id]
	participant.reconciling = false
	thread := e.threads[participant.Thread]
	if !e.readingHistory(thread) {
		waiting := thread.caughtUp
		thread.caughtUp = nil
		s.after(func() {
			for _, done := range waiting {
				close(done)
			}
		})
	}
	if err != nil {
		e.logger.Info("session history unavailable; showing the cache", "thread", thread.ID, "session", session, "error", err)
		return
	}
	if participant.Session != session {
		return
	}
	key := sessionKey{participant.Instance, session}
	if rebuild {
		e.dropVanishedTurns(s, thread, session, page.Turns)
	}
	var all []provider.Entry
	changed := false
	for _, native := range page.Turns {
		running := thread.runningTurn()
		if running != nil && running.Session == session && running.Ref == native.Ref {
			// The live stream is the turn's record while it runs.
			continue
		}
		for index := range native.Entries {
			e.withQuoteCards(&native.Entries[index])
		}
		all = append(all, native.Entries...)
		if !rebuild {
			s.putEntries(participant.Instance, session, authoredByProvider, native.Entries...)
		}
		changed = e.recordNativeTurn(s, thread, participant, native) || changed
	}
	if rebuild {
		s.tx.rebuilds = append(s.tx.rebuilds, sessionRebuild{key: key, entries: all})
		changed = true
	}
	changed = changed || len(all) > 0
	s.tx.markers[key] = marker{marker: page.Next, version: version}
	for _, seen := range page.Subagents {
		e.subagentSeen(s, thread, participant, seen)
	}
	if changed {
		e.notifyRefresh(s, thread)
	}
}

// dropVanishedTurns removes, on a rebuild, the session's turns the provider
// ran that its history no longer has: an older mapping made them, and their
// entries, the only record of them, are gone with the rebuild. A turn a
// delivery started or ran in stays: the ledger keeps that a message was
// sent. Whatever pointed at a dropped turn moves to the newest kept one.
func (e *Engine) dropVanishedTurns(s *step, thread *threadState, session string, native []provider.HistoryTurn) {
	turns, err := e.db.threadTurns(e.ctx, thread.ID, nil, 0)
	if err != nil {
		e.logger.Warn("read turns for rebuild", "thread", thread.ID, "error", err)
		return
	}
	delivered, err := e.db.deliveredTurns(e.ctx, thread.ID)
	if err != nil {
		e.logger.Warn("read deliveries for rebuild", "thread", thread.ID, "error", err)
		return
	}
	refs := make(map[string]bool, len(native))
	for _, turn := range native {
		refs[turn.Ref] = true
	}
	var kept *Turn
	latestDropped := false
	for index := range turns {
		turn := turns[index]
		ranByProvider := turn.StartedBy == StartedByProvider || turn.StartedBy == StartedByFound
		if turn.Session != session || !ranByProvider || turn.State == provider.TurnRunning || refs[turn.Ref] || delivered[turn.ID] {
			kept = &turns[index]
			continue
		}
		s.dropTurn(thread.ID, turn.ID)
		for _, id := range thread.participants {
			if participant := e.participants[id]; participant.SeenThrough == turn.ID {
				participant.SeenThrough = ""
				if kept != nil {
					participant.SeenThrough = kept.ID
				}
				s.putParticipant(participant)
			}
		}
		latestDropped = latestDropped || thread.latest != nil && thread.latest.ID == turn.ID
	}
	if latestDropped {
		thread.latest = kept
	}
}

// recordNativeTurn records a turn read from a native session: a turn the
// ledger knows settles as the provider says; one it doesn't is found (run
// in the CLI, or inherited by a fork) and placed by its start time. A turn
// whose message is a delivery the ledger has under a placeholder takes its
// real ref.
func (e *Engine) recordNativeTurn(s *step, thread *threadState, participant *participantState, native provider.HistoryTurn) bool {
	state := native.State
	if state == provider.TurnRunning && participant.live == nil {
		// Its session isn't running, so neither is the turn.
		state = provider.TurnInterrupted
	}
	if turn := e.turnFor(thread, participant, native.Ref); turn != nil {
		if turn.State == provider.TurnInterrupted && state != provider.TurnInterrupted && state.Settled() {
			turn.State, turn.StopReason, turn.Error = state, native.StopReason, native.Error
			e.putKnownTurn(s, thread, turn)
		}
		return false
	}
	for _, entry := range native.Entries {
		if entry.Delivery == "" {
			continue
		}
		placeholder := e.turnFor(thread, participant, placeholderRef(DeliveryID(entry.Delivery)))
		if placeholder == nil {
			continue
		}
		placeholder.Ref = native.Ref
		if state.Settled() {
			placeholder.State, placeholder.StopReason, placeholder.Error = state, native.StopReason, native.Error
		}
		e.putKnownTurn(s, thread, placeholder)
		return true
	}
	startedAt := native.StartedAt
	if startedAt.IsZero() {
		startedAt = s.now
	}
	turn := &Turn{
		ID: TurnID(newID()), Thread: thread.ID, Participant: participant.ID, Session: participant.Session, Ref: native.Ref,
		StartedBy: StartedByFound, State: state, StopReason: native.StopReason, Error: native.Error, StartedAt: startedAt, SettledAt: s.now,
	}
	e.putKnownTurn(s, thread, turn)
	return true
}

// putKnownTurn writes a settled turn and keeps the thread's latest current.
func (e *Engine) putKnownTurn(s *step, thread *threadState, turn *Turn) {
	s.putTurn(turn)
	if thread.latest == nil || thread.latest.ID == turn.ID || turnBefore(*thread.latest, *turn) && thread.latest.State != provider.TurnRunning {
		copied := *turn
		thread.latest = &copied
		thread.UpdatedAt = s.now
		s.putThread(thread)
	}
}
