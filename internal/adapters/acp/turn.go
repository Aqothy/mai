// Turn runtime for the ACP adapter: prompt dispatch, cancel-then-send steering,
// session/update consumption, and partial tool-call reconciliation.
//
// Prompt dispatch uses an ordered per-session model: at most one prompt is in
// flight at the agent (sessionStream.active), with accepted prompts parked in
// sessionStream.queued. The stream
// consumer — which already serializes prompt settles via in-queue Stop
// markers — is the single owner that dispatches the queued prompt when the
// active one settles, so a deferred turn.started can never overtake the
// previous turn's completion and no two goroutines ever race to finish the
// same turn.
package acp

import (
	"context"
	"fmt"
	"time"

	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/provider"
)

type toolState struct {
	itemType provider.ItemKind
	status   provider.ItemStatus
	threadID string
	turnID   string
	// call is the adapter-private accumulated ACP tool-call state, typed so
	// sparse updates overlay field-by-field instead of re-encoding the whole
	// snapshot. It is converted to provider.ToolCall before the runtime event
	// is published.
	call *toolCallPatch
	// settled marks a tombstone: the tool reached a terminal status but its
	// state is kept so trailing tool_call_updates still emit well-formed
	// ItemUpdated events
	// instead of empty-ItemType events that ingestion drops. Tombstones die
	// with the session (unbind) or the turn's collector.
	settled bool
}

// promptCollector is one maiD turn on an ACP session. All fields are guarded
// by Instance.mu.
type promptCollector struct {
	threadID  string
	turnID    string
	cancelled bool
	// startEmitted records whether turn.started was emitted for this turn.
	// Prompts queued behind another turn defer their start emission to the
	// dispatch owner so it lands strictly after the previous turn's
	// completion.
	startEmitted bool
	// completing is set when the turn's last prompt settled and its
	// turn.completed emission is underway. A new prompt must never join a
	// completing collector: the turn is over, only its completion event is
	// still travelling.
	completing               bool
	pendingPermissionCancels map[string]*pendingPermission
	settledPermissionKeys    map[string]struct{}
}

// promptJoinsCollector reports whether a prompt with turnID steers the
// collector's live turn (rather than starting a new one). Cancelled and
// completing turns never accept new prompts.
func promptJoinsCollector(collector *promptCollector, turnID string) bool {
	return collector != nil && !collector.cancelled && !collector.completing && !promptStartsNewTurn(collector, turnID)
}

func promptStartsNewTurn(collector *promptCollector, turnID string) bool {
	return collector != nil && turnID != "" && collector.turnID != "" && collector.turnID != turnID
}

// SendTurn returns once a prompt is dispatched or queued; lifecycle and content
// arrive asynchronously through runtime events.
func (h *Instance) SendTurn(ctx context.Context, input provider.SendTurnInput) error {
	if input.ThreadID == "" {
		return fmt.Errorf("provider turn requires threadId")
	}
	sessionID := h.sessionIDForThread(input.ThreadID)
	if sessionID == "" {
		return fmt.Errorf("thread %q has no ACP session", input.ThreadID)
	}
	stream := h.sessionStreamFor(sessionID)
	if stream == nil {
		return fmt.Errorf("thread %q has no live ACP session stream", input.ThreadID)
	}
	blocks, err := contentBlocks(input, h.Info().Capabilities.PromptContent)
	if err != nil {
		return err
	}
	h.mu.Lock()
	session := h.sessionLocked(sessionID)
	if session == nil || stream.closed {
		closeErr := stream.closeErr
		h.mu.Unlock()
		if closeErr == nil {
			closeErr = errSessionStreamClosed
		}
		return closeErr
	}
	prev := session.collector
	joins := promptJoinsCollector(prev, input.TurnID)
	collector := prev
	turnID := input.TurnID
	if joins {
		turnID = collector.turnID
		collector.threadID = input.ThreadID
	} else {
		if turnID == "" {
			turnID = newID()
		}
		collector = &promptCollector{threadID: input.ThreadID, turnID: turnID}
		session.collector = collector
	}
	rec := &pendingPrompt{threadID: input.ThreadID, turnID: turnID, collector: collector, blocks: blocks}

	if stream.active == nil && len(stream.queued) == 0 && prev == nil {
		// Idle session: dispatch immediately. This goroutine owns the start
		// emission; there is no previous turn whose completion could race it.
		stream.active = rec
		collector.startEmitted = true
		h.mu.Unlock()
		h.emitTurnLifecycle(sessionID, rec.threadID, rec.turnID, provider.RuntimeEventTurnStarted, provider.RuntimeEventPayload{})
		stream.session.PromptAsync(h.ctx, rec.blocks)
		return nil
	}

	stream.queued = append(stream.queued, rec)
	steering := joins && stream.active != nil && stream.active.collector == collector
	var permissionCancels []context.CancelFunc
	if steering {
		for _, pending := range collector.pendingPermissionCancels {
			permissionCancels = append(permissionCancels, pending.cancel)
		}
	}
	h.mu.Unlock()

	if steering {
		// Agents process one session prompt at a time, so cancel the in-flight
		// prompt (resolving its pending permission
		// requests) and let the stream consumer dispatch the steering prompt
		// once the agent settles the previous one. The maiD turn stays open —
		// the queued steering prompt keeps the collector from completing, so
		// the cancelled prompt's resolution cannot emit turn.completed.
		if err := h.agent().Cancel(ctx, schema.CancelNotification{SessionID: schema.SessionId(sessionID)}); err != nil {
			h.emitTurnLifecycle(sessionID, input.ThreadID, turnID, provider.RuntimeEventRuntimeWarning, provider.RuntimeEventPayload{Message: fmt.Sprintf("cancel before steering prompt failed: %v", acpRequestError(err))})
		} else {
			for _, cancel := range permissionCancels {
				cancel()
			}
		}
	}
	return nil
}

// settlePrompt applies one prompt's resolution: stale-session unbinding, the
// turn-completion decision, and the handoff to the queued prompt. Called from
// the stream consumer (in-queue Stop), stream abandonment, and the
// interrupt/stop/replacement paths that finalize a never-dispatched queued
// prompt. The caller must already have removed rec from the stream's slots.
func (h *Instance) settlePrompt(stream *sessionStream, rec *pendingPrompt, resp schema.PromptResponse, err error) {
	sessionID := stream.sessionID
	if err != nil && sessionNotFoundError(err) {
		// The agent dropped a session this thread still had bound in-process.
		// Unbind it so the next prompt's StartSession falls back through
		// resume/load to session/new instead of erroring on the same stale
		// session forever.
		h.unbindSessionID(sessionID)
		err = fmt.Errorf("%w; the stale session was released — send the prompt again to start a fresh session", acpRequestError(err))
	}

	collector := rec.collector
	h.mu.Lock()
	wasCancelled := collector.cancelled
	// The turn continues if a steering prompt for the same turn is queued;
	// otherwise this was the turn's last prompt and the turn completes.
	lastPrompt := len(stream.queued) == 0 || stream.queued[0].collector != collector
	var cancels []context.CancelFunc
	emitStart := false
	if lastPrompt {
		collector.completing = true
		for _, pending := range collector.pendingPermissionCancels {
			cancels = append(cancels, pending.cancel)
		}
		emitStart = !collector.startEmitted
		collector.startEmitted = true
	}
	h.mu.Unlock()
	for _, cancel := range cancels {
		cancel()
	}

	if !lastPrompt {
		h.settleAbandonedPromptItems(sessionID, rec, resp, err)
		if err != nil && !wasCancelled {
			h.emitTurnLifecycle(sessionID, rec.threadID, rec.turnID, provider.RuntimeEventRuntimeWarning, provider.RuntimeEventPayload{Message: acpRequestError(err).Error()})
		}
		h.finishSettledTurn(stream, collector, false)
		return
	}

	payload := provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCompleted}
	switch {
	case wasCancelled:
		payload.TurnState = provider.RuntimeTurnCancelled
		payload.StopReason = string(schema.StopReasonCancelled)
	case err != nil:
		payload.TurnState = provider.RuntimeTurnFailed
		payload.Message = acpRequestError(err).Error()
	default:
		payload.StopReason = string(resp.StopReason)
		if resp.StopReason == schema.StopReasonCancelled {
			payload.TurnState = provider.RuntimeTurnCancelled
		}
	}
	if emitStart {
		// A queued prompt can settle before it was ever dispatched (interrupt,
		// steer replacement, stream abandonment). Emit the start it deferred so
		// clients always observe a start/completion pair.
		h.emitTurnLifecycle(sessionID, rec.threadID, rec.turnID, provider.RuntimeEventTurnStarted, provider.RuntimeEventPayload{})
	}
	h.emitTurnLifecycle(sessionID, rec.threadID, rec.turnID, provider.RuntimeEventTurnCompleted, payload)
	h.finishSettledTurn(stream, collector, true)
}

// finishSettledTurn is the single owner that retires a collector and promotes
// its queued successor after completion emission.
func (h *Instance) finishSettledTurn(stream *sessionStream, settled *promptCollector, turnEnded bool) {
	sessionID := stream.sessionID
	h.mu.Lock()
	if turnEnded {
		if session := h.sessionLocked(sessionID); session != nil {
			if session.collector == settled {
				session.collector = nil
			}
			// The turn is over: post-cancel updates were dropped, so terminal
			// statuses for its interrupted tools will never arrive. Drop the
			// turn's tool reconciliation entries (open states and tombstones)
			// instead of leaking them until session unbind.
			for itemID, state := range session.toolStates {
				if state.turnID == settled.turnID {
					delete(session.toolStates, itemID)
				}
			}
		}
	}
	if len(stream.queued) == 0 || stream.active != nil || stream.closed {
		h.mu.Unlock()
		return
	}
	next := stream.queued[0]
	stream.queued = stream.queued[1:]
	stream.active = next
	emitStart := !next.collector.startEmitted
	next.collector.startEmitted = true
	h.mu.Unlock()
	if emitStart {
		h.emitTurnLifecycle(sessionID, next.threadID, next.turnID, provider.RuntimeEventTurnStarted, provider.RuntimeEventPayload{})
	}
	stream.session.PromptAsync(h.ctx, next.blocks)
}

func (h *Instance) settleAbandonedPromptItems(sessionID string, rec *pendingPrompt, resp schema.PromptResponse, err error) {
	status, ok := abandonedPromptItemStatus(resp, err)
	if !ok {
		return
	}
	h.emitOpenToolItemSettlements(sessionID, rec.threadID, rec.turnID, status)
}

func abandonedPromptItemStatus(resp schema.PromptResponse, err error) (provider.ItemStatus, bool) {
	if err != nil {
		return provider.ItemStatusFailed, true
	}
	if resp.StopReason == schema.StopReasonCancelled {
		return provider.ItemStatusInterrupted, true
	}
	return "", false
}

func (h *Instance) emitOpenToolItemSettlements(sessionID string, threadID string, turnID string, status provider.ItemStatus) {
	if threadID == "" || turnID == "" || status == "" {
		return
	}
	now := time.Now()
	var updates []provider.RuntimeEvent
	h.mu.Lock()
	session := h.sessionLocked(sessionID)
	if session == nil {
		h.mu.Unlock()
		return
	}
	for itemID, state := range session.toolStates {
		if state.threadID != threadID || state.turnID != turnID || state.status != provider.ItemStatusInProgress {
			continue
		}
		if itemID == "" || state.itemType == "" {
			continue
		}
		state.status = status
		state.settled = true
		session.toolStates[itemID] = state
		updates = append(updates, provider.RuntimeEvent{
			EventID:   provider.RuntimeEventID(newID()),
			Type:      provider.RuntimeEventItemUpdated,
			Provider:  DriverKind,
			ThreadID:  threadID,
			TurnID:    turnID,
			ItemID:    itemID,
			CreatedAt: now,
			Payload: provider.RuntimeEventPayload{
				ItemType:   state.itemType,
				ItemStatus: status,
			},
		})
	}
	listener := h.runtimeEventListener
	h.mu.Unlock()
	if listener == nil {
		return
	}
	for _, update := range updates {
		listener(update)
	}
}

func (h *Instance) emitTurnLifecycle(sessionID string, threadID string, turnID string, eventType provider.RuntimeEventType, payload provider.RuntimeEventPayload) {
	h.emitRuntimeEventForSession(sessionID, provider.RuntimeEvent{
		EventID:   provider.RuntimeEventID(newID()),
		Type:      eventType,
		Provider:  DriverKind,
		ThreadID:  threadID,
		TurnID:    turnID,
		CreatedAt: time.Now(),
		Payload:   payload,
	})
}

func (h *Instance) InterruptTurn(ctx context.Context, input provider.InterruptTurnInput) error {
	sessionID := h.sessionIDForThread(input.ThreadID)
	if sessionID == "" {
		return fmt.Errorf("thread %q has no ACP session", input.ThreadID)
	}
	if input.TurnID != "" && !h.promptCancellationMatches(sessionID, input.TurnID) {
		// Stale interrupt: session/cancel is session-scoped, so sending it would
		// cancel whichever newer prompt is running now.
		return nil
	}
	if err := h.agent().Cancel(ctx, schema.CancelNotification{SessionID: schema.SessionId(sessionID)}); err != nil {
		return acpRequestError(err)
	}
	cancels, dropped, stream := h.markPromptCancelled(sessionID, input.TurnID)
	for _, cancel := range cancels {
		cancel()
	}
	if dropped != nil {
		// The queued prompt never dispatched and no in-flight prompt will
		// settle its turn: finalize it here (emits the cancelled completion).
		h.settlePrompt(stream, dropped, schema.PromptResponse{}, nil)
	}
	return nil
}

func (h *Instance) handleACPSessionUpdate(notification schema.SessionNotification) {
	sessionID := string(notification.SessionID)
	switch u := notification.Update; u.SessionUpdate {
	case schema.SessionUpdateConfigOptionUpdate:
		h.cacheSessionState(sessionID, u.ConfigOptions, nil)
		h.emitConfigOptions(sessionID, h.combinedConfigOptions(sessionID))
		return
	case schema.SessionUpdateCurrentModeUpdate:
		if u.CurrentModeID != nil {
			ok := false
			h.mu.Lock()
			if session := h.sessionLocked(sessionID); session != nil && session.modes != nil {
				session.modes.CurrentModeID = *u.CurrentModeID
				ok = true
			}
			h.mu.Unlock()
			if ok {
				h.emitConfigOptions(sessionID, h.combinedConfigOptions(sessionID))
			}
		}
		return
	}
	update := sessionRuntimeEvent(notification)
	drop := false
	h.mu.Lock()
	session := h.sessionLocked(sessionID)
	h.scopeRuntimeEventIDsLocked(sessionID, &update)
	if collector := h.updateCollectorLocked(sessionID); collector != nil {
		if collector.cancelled || update.Payload.ItemType == provider.ItemKindUserMessage {
			// The optimistic user message is already in orchestration. ACP
			// user_message_chunk updates during a live prompt are its echo. Display
			// replay has no collector and routes through the session branch below.
			drop = true
		} else {
			update.ThreadID = collector.threadID
			update.TurnID = collector.turnID
		}
	} else if session != nil && session.threadID != "" {
		update.ThreadID = session.threadID
	}
	h.mu.Unlock()
	if drop {
		return
	}
	h.reconcileToolState(sessionID, &update, toolCallPatchFromUpdate(notification.Update))
	var cancelPermission context.CancelFunc
	if update.Type == provider.RuntimeEventItemCompleted || itemStatusSettled(update.Payload.ItemStatus) {
		cancelPermission = h.markPermissionToolSettled(sessionID, update.ThreadID, update.ItemID)
	}
	h.emitOrBufferRuntimeEvent(sessionID, update, true)
	if cancelPermission != nil {
		cancelPermission()
	}
}

// updateCollectorLocked resolves the turn that agent-initiated traffic
// (session updates, permission requests) belongs to: the collector of the
// prompt the agent is currently processing (stream.active). A queued prompt's
// collector must never claim this traffic — while a cancelled prompt drains,
// its late updates would otherwise be attributed to the follow-up turn.
// Falls back to the registered collector when no prompt is in flight.
// h.mu must be held.
func (h *Instance) updateCollectorLocked(sessionID string) *promptCollector {
	session := h.sessionLocked(sessionID)
	if session == nil {
		return nil
	}
	if session.stream != nil && session.stream.active != nil {
		return session.stream.active.collector
	}
	return session.collector
}

// scopeRuntimeEventIDsLocked converts ACP session-scoped message/tool ids into
// thread-level opaque ids before orchestration sees them. h.mu must be held.
func (h *Instance) scopeRuntimeEventIDsLocked(sessionID string, event *provider.RuntimeEvent) {
	if event == nil || event.ItemID == "" {
		return
	}
	event.ItemID = h.scopedProviderItemIDLocked(sessionID, event.ItemID)
}

func (h *Instance) scopedProviderItemIDLocked(sessionID string, providerItemID string) string {
	if providerItemID == "" {
		return ""
	}
	scope := h.sessionScopeLocked(sessionID)
	return scope + ":" + providerItemID
}

func (h *Instance) sessionScopeLocked(sessionID string) string {
	// The scope is random (not derived from the session id) so item ids from a
	// re-materialized session can never collide with items an earlier binding of
	// the same ACP session already wrote into the orchestration projection.
	session := h.sessionLocked(sessionID)
	if session == nil {
		// Stray traffic from an unbound session must not re-materialize
		// per-session state; hand out an ephemeral scope without storing it.
		return "acp-session-" + newID()
	}
	if session.scope == "" {
		session.scope = "acp-session-" + newID()
	}
	return session.scope
}

func (h *Instance) reconcileToolState(sessionID string, event *provider.RuntimeEvent, patch *toolCallPatch) {
	if event == nil || event.ItemID == "" {
		return
	}
	switch event.Type {
	case provider.RuntimeEventItemStarted, provider.RuntimeEventItemUpdated, provider.RuntimeEventItemCompleted:
	default:
		return
	}
	h.mu.Lock()
	session := h.sessionLocked(sessionID)
	if session == nil {
		h.mu.Unlock()
		return
	}
	state := session.toolStates[event.ItemID]
	if event.Type == provider.RuntimeEventItemStarted {
		// A fresh tool_call reusing an id starts a new tool run: drop any
		// previous state/tombstone so a stale terminal status is not
		// inherited, and re-arm permission requests for this tool id.
		h.clearSettledPermissionKeyLocked(sessionID, event.ThreadID, event.ItemID)
		state = toolState{}
	}
	if event.Payload.ItemType == "" {
		event.Payload.ItemType = state.itemType
	}
	if event.Payload.ItemStatus == "" {
		event.Payload.ItemStatus = state.status
	}
	if event.Type == provider.RuntimeEventItemStarted && event.Payload.ItemType == "" {
		event.Payload.ItemType = provider.ItemKindToolCall
	}
	if event.Type == provider.RuntimeEventItemStarted && event.Payload.ItemStatus == "" {
		event.Payload.ItemStatus = provider.ItemStatusInProgress
	}
	if event.Payload.ItemType != "" {
		state.itemType = event.Payload.ItemType
	}
	if event.Payload.ItemStatus != "" {
		state.status = event.Payload.ItemStatus
	}
	if event.ThreadID != "" {
		state.threadID = event.ThreadID
	}
	if event.TurnID != "" {
		state.turnID = event.TurnID
	}
	// ACP tool_call_update payloads are SPARSE (only changed fields), but the
	// provider contract requires every item event to carry the COMPLETE
	// tool-call state. Accumulate the typed private snapshot here, convert
	// it once into the neutral contract, and never publish the native envelope.
	state.call = state.call.overlay(patch)
	event.Payload.ToolCall = state.call.toolCall()
	if event.Type == provider.RuntimeEventItemCompleted || itemStatusSettled(state.status) {
		// Keep a settled tombstone (instead of deleting) so a trailing
		// tool_call_update for the settled tool still emits a well-formed
		// event; see toolState.settled.
		state.settled = true
	}
	if state.itemType != "" || state.status != "" || state.settled {
		session.toolStates[event.ItemID] = state
	}
	h.mu.Unlock()
}

func itemStatusSettled(status provider.ItemStatus) bool {
	switch status {
	case provider.ItemStatusCompleted, provider.ItemStatusFailed, provider.ItemStatusInterrupted, provider.ItemStatusDeclined:
		return true
	default:
		return false
	}
}

func (h *Instance) emitRuntimeEventForSession(sessionID string, update provider.RuntimeEvent) {
	h.emitRuntimeEventForSessionState(sessionID, update, false)
}

func (h *Instance) emitBoundRuntimeEventForSession(sessionID string, update provider.RuntimeEvent) {
	h.emitRuntimeEventForSessionState(sessionID, update, true)
}

func (h *Instance) emitRuntimeEventForSessionState(sessionID string, update provider.RuntimeEvent, requireSession bool) {
	h.mu.Lock()
	session := h.sessionLocked(sessionID)
	var collector *promptCollector
	if session != nil {
		collector = session.collector
	}
	if collector != nil {
		if update.ThreadID == "" {
			update.ThreadID = collector.threadID
		}
		if update.TurnID == "" && shouldStampActiveTurn(update.Type) {
			update.TurnID = collector.turnID
		}
	} else if update.ThreadID == "" && session != nil {
		update.ThreadID = session.threadID
	}
	h.mu.Unlock()
	h.emitOrBufferRuntimeEvent(sessionID, update, requireSession)
}

// emitOrBufferRuntimeEvent is the publication boundary for session/load. Load
// replay stays private until StartSession returns the complete ordered batch.
func (h *Instance) emitOrBufferRuntimeEvent(sessionID string, update provider.RuntimeEvent, requireSession bool) {
	h.mu.Lock()
	session := h.sessionLocked(sessionID)
	if session == nil && requireSession {
		h.mu.Unlock()
		return
	}
	if session != nil {
		if session.replayEvents != nil {
			session.replayEvents = append(session.replayEvents, update)
			h.mu.Unlock()
			return
		}
	}
	listener := h.runtimeEventListener
	h.mu.Unlock()
	if listener != nil && update.ThreadID != "" {
		listener(update)
	}
}

func shouldStampActiveTurn(eventType provider.RuntimeEventType) bool {
	switch eventType {
	case provider.RuntimeEventRequestOpened, provider.RuntimeEventRequestResolved:
		return false
	default:
		return true
	}
}

// cancellationTargetsLocked lists the session's cancellation targets: the
// in-flight prompt's collector and the registered one.
//
// They are usually the same object. They diverge because a prompt refuses to
// join a cancelled or completing collector even when the turn id matches
// (promptJoinsCollector): after an interrupt, the agent has not settled yet, so
// stream.active still holds the cancelled prompt while a re-prompt — which the
// engine steers onto the SAME turn id — registers a fresh collector. A later
// interrupt must reach both. h.mu must be held.
func cancellationTargetsLocked(session *acpSession) []*promptCollector {
	var targets []*promptCollector
	if session.stream != nil && session.stream.active != nil && session.stream.active.collector != nil {
		targets = append(targets, session.stream.active.collector)
	}
	if collector := session.collector; collector != nil && (len(targets) == 0 || targets[0] != collector) {
		targets = append(targets, collector)
	}
	return targets
}

// Shared by the read-only pre-check and the mutating mark below so they cannot
// drift; a mismatch would cancel the wrong turn.
func turnMatchesCollector(collector *promptCollector, turnID string) bool {
	return collector != nil && (turnID == "" || collector.turnID == "" || collector.turnID == turnID)
}

// promptCancellationMatches reports whether turnID names a cancellation target,
// without changing turn state. InterruptTurn checks this before sending the
// session-scoped agent cancel, which would otherwise kill a newer turn.
func (h *Instance) promptCancellationMatches(sessionID string, turnID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessionLocked(sessionID)
	if session == nil {
		return false
	}
	for _, collector := range cancellationTargetsLocked(session) {
		if turnMatchesCollector(collector, turnID) {
			return true
		}
	}
	return false
}

// markPromptCancelled cancels the targets turnID names (or all, when empty),
// removes their queued prompts, and collects their pending permission cancels.
// The dropped result is a cleared queued prompt that no in-flight prompt will
// settle; the caller must finalize it via settlePrompt.
func (h *Instance) markPromptCancelled(sessionID string, turnID string) ([]context.CancelFunc, *pendingPrompt, *sessionStream) {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessionLocked(sessionID)
	if session == nil {
		return nil, nil, nil
	}
	stream := session.stream
	matched := false
	var cancels []context.CancelFunc
	for _, collector := range cancellationTargetsLocked(session) {
		if !turnMatchesCollector(collector, turnID) {
			continue
		}
		matched = true
		collector.cancelled = true
		for _, pending := range collector.pendingPermissionCancels {
			cancels = append(cancels, pending.cancel)
		}
	}
	if !matched {
		return nil, nil, nil
	}
	var dropped *pendingPrompt
	if stream != nil && len(stream.queued) > 0 {
		kept := make([]*pendingPrompt, 0, len(stream.queued))
		for _, rec := range stream.queued {
			if !rec.collector.cancelled {
				kept = append(kept, rec)
				continue
			}
			if dropped == nil && (stream.active == nil || stream.active.collector != rec.collector) {
				// One representative settles a never-dispatched collector; all
				// queued prompts sharing it belong to the same turn lifecycle.
				dropped = rec
			}
		}
		stream.queued = kept
	}
	return cancels, dropped, stream
}
