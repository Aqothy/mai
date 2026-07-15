package orchestration

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"runtime/debug"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// ProviderRuntimeIngestion is the single place that translates provider-neutral
// runtime events into orchestration events. It owns the per-turn streaming
// state (assistant message streams, reasoning text, open provider items),
// keyed by thread+turn.
type ProviderRuntimeIngestion struct {
	engine *Engine

	replayMu  sync.Mutex
	replaying map[string]*historyReplayGate
	mu        sync.Mutex
	turns     map[turnKey]*turnState
	turnOrder []turnKey
}

type historyReplayGate struct {
	mu     sync.Mutex
	queued []provider.RuntimeEvent
	closed bool
}

type turnKey struct {
	threadID string
	turnID   string
}

func turnKeyOf(event provider.RuntimeEvent) turnKey {
	return turnKey{threadID: event.ThreadID, turnID: event.TurnID}
}

// turnState is temporary streaming state for one thread+turn. It is dropped as a
// whole when the turn settles (clearTurnBuffers).
type turnState struct {
	// assistants holds the turn's assistant message streams in dispatch order,
	// keyed by provider message/item id when present (so multi-message turns and
	// session/load replay don't collapse messages) or by turn/event id otherwise.
	assistants        []*assistantStream
	assistantSegments map[string]uint64
	idlessUserMessage MessageID
	reasoning         string
	// reasoningPending is the slice of reasoning not yet flushed as a textDelta
	// event; reasoning above keeps the segment's FULL text for the settle
	// checkpoint.
	reasoningPending string
	// reasoningSegment is incremented whenever reasoning resumes after another
	// timeline entry. Consecutive chunks share one item; separated chunks do not.
	reasoningSegment uint64
	// reasoningAttachments accumulates non-text content blocks (images, audio,
	// resources) the agent attached to its thought stream — ACP thought chunks
	// are full ContentBlocks, not just text.
	reasoningAttachments []provider.Attachment
	// reasoningActive distinguishes "no reasoning this turn" (no settle item)
	// from "reasoning streamed, possibly empty" (settle checkpoint emitted).
	reasoningActive bool
	// openItems tracks in-progress provider items (tool calls, file changes, …)
	// so a turn that settles WITHOUT the provider completing them (interrupt,
	// turn failure, provider death) can settle them too. Adapters drop
	// post-cancel provider updates, so this is the only settle path on interrupt.
	openItems map[string]struct{}
}

// assistantStream buffers one assistant message's content between shared
// ingestion-ticker flushes.
type assistantStream struct {
	key         string
	id          MessageID
	text        string
	attachments []provider.Attachment
}

// assistantFlush is buffered content copied out under the ingestion lock, so
// the event append (which blocks on the engine worker) can run outside it.
type assistantFlush struct {
	id          MessageID
	text        string
	attachments []provider.Attachment
}

// textFlushInterval is the cadence of the single ingestion-owned flush ticker.
// Semantic boundaries still flush immediately. A shared tick keeps concurrent
// providers bounded without per-stream goroutines or timers.
var textFlushInterval = 75 * time.Millisecond

func (t *turnState) streamByKey(key string) *assistantStream {
	for _, stream := range t.assistants {
		if stream.key == key {
			return stream
		}
	}
	return nil
}

func NewProviderRuntimeIngestion(engine *Engine) *ProviderRuntimeIngestion {
	return &ProviderRuntimeIngestion{
		engine:    engine,
		turns:     make(map[turnKey]*turnState),
		replaying: make(map[string]*historyReplayGate),
	}
}

func (i *ProviderRuntimeIngestion) ensureTurnLocked(key turnKey) *turnState {
	ts := i.turns[key]
	if ts == nil {
		ts = &turnState{}
		i.turns[key] = ts
		i.turnOrder = append(i.turnOrder, key)
	}
	return ts
}

// Run consumes the provider runtime event stream (from ProviderService.Events)
// until the context is cancelled or the channel closes, translating each event
// into orchestration events via Ingest.
func (i *ProviderRuntimeIngestion) Run(ctx context.Context, events <-chan provider.RuntimeEvent) {
	ticker := time.NewTicker(textFlushInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			i.flushPendingText(now)
		case event, ok := <-events:
			if !ok {
				i.flushPendingText(time.Now())
				return
			}
			i.ingestRecovered(event)
		}
	}
}

// ingestRecovered keeps one malformed provider event from killing the ingestion
// loop (which would stall the hub and, through publish backpressure, the
// adapters' read loops).
func (i *ProviderRuntimeIngestion) ingestRecovered(event provider.RuntimeEvent) {
	defer func() {
		if rec := recover(); rec != nil {
			log.Printf("orchestration: ingestion panicked on %s (thread %s): %v\n%s", event.Type, event.ThreadID, rec, debug.Stack())
		}
	}()
	i.Ingest(event)
}

func (i *ProviderRuntimeIngestion) Ingest(event provider.RuntimeEvent) {
	if event.ThreadID == "" {
		return
	}
	i.replayMu.Lock()
	gate := i.replaying[event.ThreadID]
	i.replayMu.Unlock()
	if gate != nil {
		gate.mu.Lock()
		if !gate.closed {
			gate.queued = append(gate.queued, event)
			gate.mu.Unlock()
			return
		}
		gate.mu.Unlock()
	}
	i.ingest(event)
}

func (i *ProviderRuntimeIngestion) ingest(event provider.RuntimeEvent) {
	if i.eventFromStaleProviderInstance(event) {
		return
	}
	if event.Payload.ItemType != provider.ItemKindUserMessage {
		i.endIDLessUserMessage(event)
	}
	createdAt := event.CreatedAt
	if createdAt.IsZero() {
		createdAt = time.Now()
	}
	switch event.Type {
	case provider.RuntimeEventContentDelta:
		i.ingestContentDelta(event, createdAt)
	case provider.RuntimeEventItemStarted:
		i.ingestItem(event, createdAt, itemStatusOr(event.Payload.ItemStatus, provider.ItemStatusInProgress))
	case provider.RuntimeEventItemUpdated:
		// An empty status means "preserve the existing item's status" on upsert.
		i.ingestItem(event, createdAt, event.Payload.ItemStatus)
	case provider.RuntimeEventItemCompleted:
		i.ingestItem(event, createdAt, itemStatusOr(event.Payload.ItemStatus, provider.ItemStatusCompleted))
	case provider.RuntimeEventTurnPlanUpdated:
		i.ingestPlanUpdated(event, createdAt)
	case provider.RuntimeEventRequestOpened:
		i.ingestRequestOpened(event, createdAt)
	case provider.RuntimeEventRequestResolved:
		i.ingestRequestResolved(event, createdAt)
	case provider.RuntimeEventConfigOptionsUpdated:
		i.ingestConfigOptions(event, createdAt)
	case provider.RuntimeEventThreadMetadataUpdate:
		i.ingestThreadMetadata(event, createdAt)
	case provider.RuntimeEventThreadTokenUsage:
		i.ingestTokenUsage(event, createdAt)
	case provider.RuntimeEventTurnStarted:
		i.ingestTurnStarted(event, createdAt)
	case provider.RuntimeEventTurnCompleted:
		i.ingestTurnCompleted(event, createdAt)
	case provider.RuntimeEventRuntimeWarning:
		i.ingestRuntimeWarning(event, createdAt)
	case provider.RuntimeEventRuntimeError:
		i.ingestRuntimeError(event, createdAt)
	}
}

// RestoreHistory loads without blocking live ingestion, then suppresses ticker
// flushes for only this thread while committing replay, completion, and ready.
// The provider contract keeps same-thread setup events in the returned batch.
func (i *ProviderRuntimeIngestion) RestoreHistory(
	threadID string,
	load func() (provider.StartSessionResult, error),
	ready func(provider.Session),
) error {
	gate := &historyReplayGate{}
	i.replayMu.Lock()
	i.replaying[threadID] = gate
	i.replayMu.Unlock()
	result, err := load()
	if err != nil {
		gate.mu.Lock()
		gate.closed = true
		gate.queued = nil
		gate.mu.Unlock()
		i.replayMu.Lock()
		delete(i.replaying, threadID)
		i.replayMu.Unlock()
		return err
	}
	for _, event := range result.Replay {
		i.ingest(event)
	}
	if result.HistoryUnavailable {
		i.ingest(provider.RuntimeEvent{
			Type:               provider.RuntimeEventRuntimeWarning,
			Provider:           result.Session.Provider,
			ProviderName:       result.Session.ProviderName,
			ProviderInstanceID: result.Session.ProviderInstanceID,
			Generation:         result.Session.Generation,
			ThreadID:           threadID,
			Payload: provider.RuntimeEventPayload{
				Message: "history unavailable for this agent",
			},
		})
	}
	for {
		gate.mu.Lock()
		queued := gate.queued
		if len(queued) == 0 {
			i.completeHistoryReplay(threadID)
			ready(result.Session)
			gate.closed = true
			gate.mu.Unlock()
			break
		}
		gate.queued = nil
		gate.mu.Unlock()
		for _, event := range queued {
			i.ingest(event)
		}
	}
	i.replayMu.Lock()
	delete(i.replaying, threadID)
	i.replayMu.Unlock()
	return nil
}

func (i *ProviderRuntimeIngestion) completeHistoryReplay(threadID string) {
	createdAt := time.Now()
	i.completeThreadText(threadID, createdAt)
	i.clearThreadBuffers(threadID)
	i.record(EventInput{
		Type:       EventThreadHistoryReplayCompleted,
		ThreadID:   ThreadID(threadID),
		OccurredAt: createdAt,
	})
}

func (i *ProviderRuntimeIngestion) ingestContentDelta(event provider.RuntimeEvent, createdAt time.Time) {
	switch event.Payload.StreamKind {
	case provider.RuntimeContentAssistantText:
		// Reasoning->text switch (interleaved thinking): settle the segment so
		// reasoning that resumes later starts a new entry after this message.
		i.settleReasoning(event, provider.ItemStatusCompleted, createdAt)
		i.bufferAssistantDelta(event, createdAt)
	case provider.RuntimeContentReasoningText:
		i.ingestReasoningDelta(event, createdAt)
	}
}

func (i *ProviderRuntimeIngestion) ingestReasoningDelta(event provider.RuntimeEvent, createdAt time.Time) {
	i.mu.Lock()
	ts := i.ensureTurnLocked(turnKeyOf(event))
	resumed := !ts.reasoningActive
	if resumed {
		ts.reasoningSegment++
	}
	ts.reasoning += event.Payload.Delta
	ts.reasoningPending += event.Payload.Delta
	ts.reasoningAttachments = append(ts.reasoningAttachments, event.Payload.Attachments...)
	ts.reasoningActive = true
	itemID := reasoningItemID(event, ts.reasoningSegment)
	var full *reasoningPayload
	if len(event.Payload.Attachments) > 0 {
		// Non-text content (ACP thought chunks are full ContentBlocks) flushes
		// immediately as the COMPLETE replacement payload, so an attachment is
		// never hidden until the settle checkpoint.
		full = &reasoningPayload{Text: ts.reasoning, Attachments: append([]provider.Attachment(nil), ts.reasoningAttachments...)}
		ts.reasoningPending = ""
	}
	i.mu.Unlock()
	if resumed {
		// Text->reasoning switch: text that resumes later starts a new message
		// after this reasoning entry.
		i.completeOpenAssistantMessages(event, createdAt)
	}
	if full == nil {
		return
	}
	item := &Item{ID: itemID, Kind: provider.ItemKindReasoning, Status: provider.ItemStatusInProgress, TurnID: TurnID(event.TurnID), Payload: marshalEventPayload(full)}
	i.recordItem(event, item, createdAt)
}

// reasoningPayload is orchestration's own payload shape for reasoning items:
// the accumulated thought text plus any non-text content blocks the agent
// attached to its thought stream.
type reasoningPayload struct {
	Text        string                `json:"text"`
	Attachments []provider.Attachment `json:"attachments,omitempty"`
}

func (i *ProviderRuntimeIngestion) settleReasoning(event provider.RuntimeEvent, status provider.ItemStatus, createdAt time.Time) {
	i.mu.Lock()
	ts := i.turns[turnKeyOf(event)]
	var checkpoint reasoningPayload
	active := ts != nil && ts.reasoningActive
	var itemID string
	if active {
		checkpoint = reasoningPayload{Text: ts.reasoning, Attachments: ts.reasoningAttachments}
		itemID = reasoningItemID(event, ts.reasoningSegment)
		ts.reasoning = ""
		ts.reasoningPending = ""
		ts.reasoningAttachments = nil
		ts.reasoningActive = false
	}
	i.mu.Unlock()
	if !active {
		return
	}
	item := &Item{ID: itemID, Kind: provider.ItemKindReasoning, Status: status, Payload: marshalEventPayload(checkpoint), TurnID: TurnID(event.TurnID)}
	i.recordItem(event, item, createdAt)
}

func reasoningItemID(event provider.RuntimeEvent, segment uint64) string {
	base := "reasoning:" + event.ThreadID + ":" + event.TurnID
	if segment <= 1 {
		return base
	}
	return fmt.Sprintf("%s:%d", base, segment)
}

func (i *ProviderRuntimeIngestion) ingestItem(event provider.RuntimeEvent, createdAt time.Time, status provider.ItemStatus) {
	if event.Payload.ItemType == provider.ItemKindUserMessage {
		i.ingestUserMessage(event, createdAt)
		return
	}
	if event.Payload.ItemType == provider.ItemKindAssistantMessage {
		i.ingestAssistantMessageStatus(event, createdAt, status)
		return
	}
	kind := event.Payload.ItemType
	if kind == "" {
		return
	}
	// A newly started provider item is a chronological boundary. Settle the
	// current reasoning segment and buffered messages before recording the
	// item; updates/completion of an existing item stay anchored and do not
	// split later content.
	if event.Type == provider.RuntimeEventItemStarted {
		i.settleReasoning(event, provider.ItemStatusCompleted, createdAt)
		i.completeOpenAssistantMessages(event, createdAt)
	}
	itemID := firstNonEmpty(event.ItemID, string(event.EventID))
	i.trackOpenItem(event, itemID, status)
	// Payloads are REPLACED downstream, so one is emitted only when the event
	// carries provider data (the ACP adapter sends the complete accumulated
	// tool-call state on every update); status-only updates keep the previous
	// payload.
	var payload json.RawMessage
	if len(event.Payload.Data) > 0 {
		payload = marshalEventPayload(map[string]any{"itemType": event.Payload.ItemType, "data": event.Payload.Data})
	}
	item := &Item{ID: itemID, Kind: kind, Title: firstNonEmpty(event.Payload.Title, event.Payload.Detail), Status: status, Payload: payload, TurnID: TurnID(event.TurnID)}
	i.recordItem(event, item, createdAt)
}

// trackOpenItem keeps the per-turn set of provider items still in progress. A
// status-less update ("preserve existing") leaves tracking unchanged; any
// settled status untracks the item.
func (i *ProviderRuntimeIngestion) trackOpenItem(event provider.RuntimeEvent, itemID string, status provider.ItemStatus) {
	if event.TurnID == "" || itemID == "" {
		return
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	switch status {
	case provider.ItemStatusInProgress:
		ts := i.ensureTurnLocked(turnKeyOf(event))
		if ts.openItems == nil {
			ts.openItems = make(map[string]struct{})
		}
		ts.openItems[itemID] = struct{}{}
	case "":
	default:
		if ts := i.turns[turnKeyOf(event)]; ts != nil {
			delete(ts.openItems, itemID)
		}
	}
}

// settleOpenItems closes out provider items still in progress when their turn
// settles abnormally (failed/interrupted). A normally completed turn does not
// settle items: a well-behaved provider already settled them, and fabricating
// "completed" for one it did not would misreport tool outcomes.
func (i *ProviderRuntimeIngestion) settleOpenItems(event provider.RuntimeEvent, status provider.ItemStatus, createdAt time.Time) {
	if event.TurnID == "" || status != provider.ItemStatusFailed && status != provider.ItemStatusInterrupted {
		return
	}
	i.mu.Lock()
	var open map[string]struct{}
	if ts := i.turns[turnKeyOf(event)]; ts != nil {
		open = ts.openItems
		ts.openItems = nil
	}
	i.mu.Unlock()
	for itemID := range open {
		// Kind/title/payload are omitted so the projection's upsert merge keeps
		// the existing item and only the status changes.
		item := &Item{ID: itemID, Status: status, TurnID: TurnID(event.TurnID)}
		i.recordItem(event, item, createdAt)
	}
}

func (i *ProviderRuntimeIngestion) ingestUserMessage(event provider.RuntimeEvent, createdAt time.Time) {
	// A provider-replayed user message starts the next chronological turn. Flush
	// any preceding assistant/reasoning content first. Replay boundary events do
	// not necessarily carry the preceding turn id, so flush the whole thread in
	// provider encounter order.
	i.completeThreadText(event.ThreadID, createdAt)
	messageID := i.userMessageID(event)
	text := firstNonEmpty(event.Payload.Detail, event.Payload.Message, event.Payload.Delta)
	i.record(EventInput{Type: EventThreadMessageSent, ThreadID: ThreadID(event.ThreadID), OccurredAt: createdAt, Payload: EventPayload{MessageID: messageID, Role: MessageRoleUser, Text: text, Attachments: event.Payload.Attachments, TurnID: TurnID(event.TurnID), CreatedAt: createdAt, UpdatedAt: createdAt}})
}

func (i *ProviderRuntimeIngestion) userMessageID(event provider.RuntimeEvent) MessageID {
	if id := firstNonEmpty(event.ItemID, event.TurnID); id != "" {
		i.endIDLessUserMessage(event)
		return MessageID("user:" + id)
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	ts := i.ensureTurnLocked(turnKeyOf(event))
	if ts.idlessUserMessage == "" {
		ts.idlessUserMessage = MessageID("user:" + newID("replay"))
	}
	return ts.idlessUserMessage
}

func (i *ProviderRuntimeIngestion) endIDLessUserMessage(event provider.RuntimeEvent) {
	i.mu.Lock()
	if ts := i.turns[turnKeyOf(event)]; ts != nil {
		ts.idlessUserMessage = ""
	}
	i.mu.Unlock()
}

func (i *ProviderRuntimeIngestion) ingestAssistantMessageStatus(event provider.RuntimeEvent, createdAt time.Time, status provider.ItemStatus) {
	if status != provider.ItemStatusCompleted {
		return
	}
	for _, flush := range i.takeAssistantMessages(event) {
		i.recordAssistantMessage(event, flush, createdAt)
	}
}

func (i *ProviderRuntimeIngestion) ingestPlanUpdated(event provider.RuntimeEvent, createdAt time.Time) {
	entries := event.Payload.PlanEntries
	if entries == nil {
		entries = []provider.PlanEntry{}
	}
	i.record(EventInput{Type: EventThreadPlanUpdated, ThreadID: ThreadID(event.ThreadID), OccurredAt: createdAt, Payload: EventPayload{Plan: &Plan{Entries: entries}}})
}

func (i *ProviderRuntimeIngestion) ingestRequestOpened(event provider.RuntimeEvent, createdAt time.Time) {
	approval := &ApprovalEvent{RequestID: event.RequestID, TurnID: TurnID(event.TurnID), RequestType: event.Payload.RequestType, Args: append(json.RawMessage(nil), event.Payload.Args...), Options: event.Payload.Options, Detail: event.Payload.Detail}
	i.record(EventInput{Type: EventThreadApprovalOpened, ThreadID: ThreadID(event.ThreadID), OccurredAt: createdAt, Payload: EventPayload{Approval: approval}})
}

func (i *ProviderRuntimeIngestion) ingestRequestResolved(event provider.RuntimeEvent, createdAt time.Time) {
	approval := &ApprovalEvent{RequestID: event.RequestID, TurnID: TurnID(event.TurnID), RequestType: event.Payload.RequestType, Decision: approvalDecisionOrCancel(event.Payload.Decision), OptionID: optionIDFromResolution(event.Payload.Resolution), Detail: event.Payload.Detail, Cancelled: event.Payload.Cancelled}
	i.record(EventInput{Type: EventThreadApprovalResolved, ThreadID: ThreadID(event.ThreadID), OccurredAt: createdAt, Payload: EventPayload{Approval: approval}})
}

func (i *ProviderRuntimeIngestion) ingestConfigOptions(event provider.RuntimeEvent, createdAt time.Time) {
	i.record(EventInput{Type: EventThreadConfigOptionsUpdated, ThreadID: ThreadID(event.ThreadID), OccurredAt: createdAt, Payload: EventPayload{ConfigOptions: event.Payload.ConfigOptions}})
}

func (i *ProviderRuntimeIngestion) ingestThreadMetadata(event provider.RuntimeEvent, createdAt time.Time) {
	if event.Payload.SlashCommands != nil {
		i.record(EventInput{Type: EventThreadSlashCommandsUpdated, ThreadID: ThreadID(event.ThreadID), OccurredAt: createdAt, Payload: EventPayload{SlashCommands: event.Payload.SlashCommands}})
	}
	if event.Payload.Title != "" {
		i.record(EventInput{Type: EventThreadMetaUpdated, ThreadID: ThreadID(event.ThreadID), OccurredAt: createdAt, Payload: EventPayload{Title: event.Payload.Title}})
	}
}

func (i *ProviderRuntimeIngestion) ingestTokenUsage(event provider.RuntimeEvent, createdAt time.Time) {
	if event.Payload.TokenUsage == nil {
		return
	}
	i.record(EventInput{Type: EventThreadTokenUsageUpdated, ThreadID: ThreadID(event.ThreadID), OccurredAt: createdAt, Payload: EventPayload{TokenUsage: event.Payload.TokenUsage}})
}

func (i *ProviderRuntimeIngestion) ingestTurnStarted(event provider.RuntimeEvent, createdAt time.Time) {
	// The engine derives the running binding from the live thread and drops
	// stale/duplicate starts (no session, stopped session, conflicting turn,
	// already-running turn).
	i.recordSessionUpdate(event.ThreadID, sessionUpdate{Kind: sessionUpdateTurnStarted, TurnID: TurnID(event.TurnID)}, createdAt)
}

func (i *ProviderRuntimeIngestion) ingestTurnCompleted(event provider.RuntimeEvent, createdAt time.Time) {
	// Local streams/buffers settle even when the engine drops the settle as
	// stale below — otherwise the turn's buffered text never flushes and its
	// turnState entry leaks.
	i.settleTurn(event, reasoningStatusFromTurnState(event.Payload.TurnState), createdAt)
	if event.Payload.TurnState == provider.RuntimeTurnFailed {
		failureMessage := firstNonEmpty(event.Payload.Message, event.Payload.Detail, event.Payload.StopReason, "Turn failed")
		item := &Item{ID: firstNonEmpty(string(event.EventID), newID("error")), Kind: provider.ItemKindError, Title: failureMessage, Status: provider.ItemStatusFailed, Payload: marshalEventPayload(map[string]any{"detail": failureMessage}), TurnID: TurnID(event.TurnID), CreatedAt: createdAt, UpdatedAt: createdAt}
		i.recordItem(event, item, createdAt)
	}
	update := sessionUpdate{Kind: sessionUpdateTurnSettled, TurnID: TurnID(event.TurnID), TurnState: event.Payload.TurnState, StopReason: event.Payload.StopReason, Error: firstNonEmpty(event.Payload.Message, event.Payload.Detail)}
	if i.recordSessionUpdate(event.ThreadID, update, createdAt) {
		i.settleSiblingTurns(event, createdAt)
	}
}

func (i *ProviderRuntimeIngestion) ingestRuntimeWarning(event provider.RuntimeEvent, createdAt time.Time) {
	i.completeThreadText(event.ThreadID, createdAt)
	message := firstNonEmpty(event.Payload.Message, event.Payload.Detail, "Runtime warning")
	item := &Item{ID: firstNonEmpty(string(event.EventID), newID("warning")), Kind: provider.ItemKindWarning, Title: message, Status: provider.ItemStatusCompleted, Payload: marshalEventPayload(map[string]any{"detail": message, "level": "warning"}), TurnID: TurnID(event.TurnID)}
	i.recordItem(event, item, createdAt)
}

func (i *ProviderRuntimeIngestion) ingestRuntimeError(event provider.RuntimeEvent, createdAt time.Time) {
	message := firstNonEmpty(event.Payload.Message, event.Payload.Detail, "Runtime error")
	item := &Item{ID: firstNonEmpty(string(event.EventID), newID("error")), Kind: provider.ItemKindError, Title: message, Status: provider.ItemStatusFailed, Payload: marshalEventPayload(map[string]any{"detail": message}), TurnID: TurnID(event.TurnID)}
	// A turn-less error settles the streams of the thread's active turn. This
	// read only steers local buffer cleanup — the authoritative staleness
	// decision for the session status happens in the engine below.
	cleanupEvent := event
	if cleanupEvent.TurnID == "" {
		if view, ok := i.engine.SessionView(ThreadID(event.ThreadID)); ok && view.Session != nil {
			cleanupEvent.TurnID = string(view.Session.ActiveTurnID)
		}
	}
	i.settleTurn(cleanupEvent, provider.ItemStatusFailed, createdAt)
	i.recordItem(event, item, createdAt)
	// The update carries the ORIGINAL turn id: a stale turn-scoped error is
	// dropped by the engine instead of failing the current turn; an empty
	// turn id fails the thread's current session state.
	if i.recordSessionUpdate(event.ThreadID, sessionUpdate{Kind: sessionUpdateError, TurnID: TurnID(event.TurnID), Error: message}, createdAt) {
		i.settleSiblingTurns(cleanupEvent, createdAt)
	}
}

// eventFromStaleProviderInstance runs for EVERY runtime event (including each
// streamed delta), so it must use the cheap SessionView, never Engine.Thread.
func (i *ProviderRuntimeIngestion) eventFromStaleProviderInstance(event provider.RuntimeEvent) bool {
	if event.ProviderInstanceID == "" {
		return false
	}
	view, ok := i.engine.SessionView(ThreadID(event.ThreadID))
	if !ok {
		return false
	}
	if view.Session != nil && view.Session.ProviderInstanceID != "" {
		if view.Session.ProviderInstanceID != event.ProviderInstanceID {
			return true
		}
		// StartSession may emit metadata before it returns the replacement
		// generation to the reactor. Keep both generations admissible during that
		// short prebind window; the materialized binding below closes the fence.
		if view.Session.Status == SessionStatusStarting {
			return false
		}
		return event.Generation != 0 && view.Session.ProviderGeneration != 0 && event.Generation != view.Session.ProviderGeneration
	}
	return view.ProviderInstanceID != "" && view.ProviderInstanceID != event.ProviderInstanceID
}

func (i *ProviderRuntimeIngestion) clearTurnBuffers(event provider.RuntimeEvent) {
	i.mu.Lock()
	i.removeTurnLocked(turnKeyOf(event))
	i.mu.Unlock()
}

func (i *ProviderRuntimeIngestion) clearThreadBuffers(threadID string) {
	i.mu.Lock()
	kept := i.turnOrder[:0]
	for _, key := range i.turnOrder {
		if key.threadID == threadID {
			delete(i.turns, key)
			continue
		}
		kept = append(kept, key)
	}
	i.turnOrder = kept
	i.mu.Unlock()
}

func (i *ProviderRuntimeIngestion) removeTurnLocked(target turnKey) {
	delete(i.turns, target)
	for index, key := range i.turnOrder {
		if key != target {
			continue
		}
		copy(i.turnOrder[index:], i.turnOrder[index+1:])
		i.turnOrder = i.turnOrder[:len(i.turnOrder)-1]
		return
	}
}

func (i *ProviderRuntimeIngestion) threadTurnKeys(threadID string) []turnKey {
	i.mu.Lock()
	defer i.mu.Unlock()
	keys := make([]turnKey, 0)
	for _, key := range i.turnOrder {
		if key.threadID == threadID {
			keys = append(keys, key)
		}
	}
	return keys
}

func (i *ProviderRuntimeIngestion) completeThreadText(threadID string, createdAt time.Time) {
	for _, key := range i.threadTurnKeys(threadID) {
		event := provider.RuntimeEvent{ThreadID: key.threadID, TurnID: key.turnID}
		i.settleReasoning(event, provider.ItemStatusCompleted, createdAt)
		i.completeOpenAssistantMessages(event, createdAt)
	}
}

// settleTurn closes out ingestion's local streaming state for the event's
// thread+turn: buffered assistant messages are flushed, reasoning gets its
// settle checkpoint, open provider items are settled (for abnormal statuses),
// and the turn's buffers are dropped. It runs even when the engine drops the
// corresponding settle update as stale — otherwise the turn's buffered text
// would never reach clients and its turns-map entry would leak.
func (i *ProviderRuntimeIngestion) settleTurn(event provider.RuntimeEvent, status provider.ItemStatus, createdAt time.Time) {
	for _, flush := range i.takeAssistantMessages(event) {
		i.recordAssistantMessage(event, flush, createdAt)
	}
	i.settleReasoning(event, status, createdAt)
	i.settleOpenItems(event, status, createdAt)
	i.clearTurnBuffers(event)
}

// settleSiblingTurns settles the buffered streams of the thread's OTHER turns
// once the engine accepted a settle for the thread's current turn: those
// older turns will never receive their own terminal event (it was lost or
// superseded), so their streams settle as interrupted here instead of
// leaking.
func (i *ProviderRuntimeIngestion) settleSiblingTurns(event provider.RuntimeEvent, createdAt time.Time) {
	for _, key := range i.threadTurnKeys(event.ThreadID) {
		if key.turnID == event.TurnID {
			continue
		}
		i.settleTurn(provider.RuntimeEvent{ThreadID: key.threadID, TurnID: key.turnID}, provider.ItemStatusInterrupted, createdAt)
	}
}

// ensureAssistantStreamLocked returns the assistant stream this event belongs
// to, creating it (with its message id) on first sight. i.mu must be held.
func (i *ProviderRuntimeIngestion) ensureAssistantStreamLocked(event provider.RuntimeEvent) *assistantStream {
	ts := i.ensureTurnLocked(turnKeyOf(event))
	key := assistantStreamDiscriminator(event)
	if stream := ts.streamByKey(key); stream != nil {
		return stream
	}
	if ts.assistantSegments == nil {
		ts.assistantSegments = make(map[string]uint64)
	}
	ts.assistantSegments[key]++
	base := "assistant:" + assistantMessageBase(event)
	if segment := ts.assistantSegments[key]; segment > 1 {
		base = fmt.Sprintf("%s:segment:%d", base, segment)
	}
	stream := &assistantStream{key: key, id: MessageID(base)}
	ts.assistants = append(ts.assistants, stream)
	return stream
}

// bufferAssistantDelta coalesces chunks for the shared ingestion ticker. The
// projection and clients append each flushed chunk by messageId.
func (i *ProviderRuntimeIngestion) bufferAssistantDelta(event provider.RuntimeEvent, createdAt time.Time) {
	i.mu.Lock()
	stream := i.ensureAssistantStreamLocked(event)
	stream.text += event.Payload.Delta
	stream.attachments = append(stream.attachments, event.Payload.Attachments...)
	if len(event.Payload.Attachments) == 0 {
		i.mu.Unlock()
		return
	}
	flush := assistantFlush{id: stream.id, text: stream.text, attachments: stream.attachments}
	stream.text, stream.attachments = "", nil
	i.mu.Unlock()
	i.recordAssistantMessage(event, flush, createdAt)
}

type pendingTextFlush struct {
	event     provider.RuntimeEvent
	assistant *assistantFlush
	reasoning *Item
}

// flushPendingText runs only from Run's ticker case. It copies every pending
// provider stream under the ingestion lock, then releases the lock before
// entering the engine's serialized append queue.
func (i *ProviderRuntimeIngestion) flushPendingText(now time.Time) {
	i.replayMu.Lock()
	replaying := make(map[string]struct{}, len(i.replaying))
	for threadID, gate := range i.replaying {
		gate.mu.Lock()
		if !gate.closed {
			replaying[threadID] = struct{}{}
		}
		gate.mu.Unlock()
	}
	i.replayMu.Unlock()

	i.mu.Lock()
	var pending []pendingTextFlush
	for _, key := range i.turnOrder {
		if _, replaying := replaying[key.threadID]; replaying {
			continue
		}
		ts := i.turns[key]
		event := provider.RuntimeEvent{ThreadID: key.threadID, TurnID: key.turnID}
		for _, stream := range ts.assistants {
			if stream.text == "" && len(stream.attachments) == 0 {
				continue
			}
			flush := assistantFlush{id: stream.id, text: stream.text, attachments: stream.attachments}
			stream.text, stream.attachments = "", nil
			pending = append(pending, pendingTextFlush{event: event, assistant: &flush})
		}
		if ts.reasoningActive && ts.reasoningPending != "" {
			item := &Item{ID: reasoningItemID(event, ts.reasoningSegment), Kind: provider.ItemKindReasoning, Status: provider.ItemStatusInProgress, TextDelta: ts.reasoningPending, TurnID: TurnID(key.turnID)}
			ts.reasoningPending = ""
			pending = append(pending, pendingTextFlush{event: event, reasoning: item})
		}
	}
	i.mu.Unlock()

	for _, flush := range pending {
		if flush.assistant != nil {
			i.recordAssistantMessage(flush.event, *flush.assistant, now)
		} else {
			i.recordItem(flush.event, flush.reasoning, now)
		}
	}
}

// completeOpenAssistantMessages settles every assistant message still open on
// the event's turn, so text arriving later starts a new segment message
// instead of merging into one anchored earlier in the timeline.
func (i *ProviderRuntimeIngestion) completeOpenAssistantMessages(event provider.RuntimeEvent, createdAt time.Time) {
	boundary := event
	boundary.ItemID = "" // turn-wide: settle every stream, not just the event's item
	for _, flush := range i.takeAssistantMessages(boundary) {
		i.recordAssistantMessage(event, flush, createdAt)
	}
}

// takeAssistantMessages removes the streams an event addresses — the one
// matching its message/item id when it carries one, otherwise every stream of
// its turn — and returns their unflushed content.
func (i *ProviderRuntimeIngestion) takeAssistantMessages(event provider.RuntimeEvent) []assistantFlush {
	i.mu.Lock()
	defer i.mu.Unlock()
	ts := i.turns[turnKeyOf(event)]
	if ts == nil {
		return nil
	}
	var streams []*assistantStream
	if event.ItemID != "" {
		if stream := ts.streamByKey(assistantStreamDiscriminator(event)); stream != nil {
			streams = []*assistantStream{stream}
		}
	} else {
		streams = ts.assistants
	}
	if len(streams) == 0 {
		return nil
	}
	flushes := make([]assistantFlush, 0, len(streams))
	drop := make(map[*assistantStream]struct{}, len(streams))
	for _, stream := range streams {
		flushes = append(flushes, assistantFlush{id: stream.id, text: stream.text, attachments: stream.attachments})
		drop[stream] = struct{}{}
	}
	kept := ts.assistants[:0]
	for _, stream := range ts.assistants {
		if _, ok := drop[stream]; !ok {
			kept = append(kept, stream)
		}
	}
	ts.assistants = kept
	return flushes
}

// assistantStreamDiscriminator distinguishes assistant messages WITHIN a turn:
// the provider message/item id when present, else the turn (one message per
// turn), else one contiguous ID-less stream. The "replay" fallback is retained
// because it is part of the persisted message ID namespace.
func assistantStreamDiscriminator(event provider.RuntimeEvent) string {
	return firstNonEmpty(event.ItemID, event.TurnID, "replay")
}

func assistantMessageBase(event provider.RuntimeEvent) string {
	return firstNonEmpty(event.ItemID, event.TurnID, "replay:"+event.ThreadID)
}

func (i *ProviderRuntimeIngestion) record(input EventInput) {
	if _, err := i.engine.AppendEvent(context.Background(), input); err != nil {
		select {
		case <-i.engine.closed:
			return // normal teardown; there is no consumer to diagnose or unblock
		default:
		}
		log.Printf("orchestration: failed to append ingested event %q for thread %q: %v", input.Type, input.ThreadID, err)
	}
}

func (i *ProviderRuntimeIngestion) recordItem(event provider.RuntimeEvent, item *Item, createdAt time.Time) {
	i.record(EventInput{Type: EventThreadItemUpserted, ThreadID: ThreadID(event.ThreadID), OccurredAt: createdAt, Payload: EventPayload{Item: item}})
}

// recordAssistantMessage emits one message-sent event carrying flushed
// content; an empty flush emits nothing.
func (i *ProviderRuntimeIngestion) recordAssistantMessage(event provider.RuntimeEvent, flush assistantFlush, createdAt time.Time) {
	if flush.text == "" && len(flush.attachments) == 0 {
		return
	}
	i.record(EventInput{Type: EventThreadMessageSent, ThreadID: ThreadID(event.ThreadID), Actor: ActorKindServer, OccurredAt: createdAt, Payload: EventPayload{MessageID: flush.id, Role: MessageRoleAssistant, Text: flush.text, Attachments: flush.attachments, TurnID: TurnID(event.TurnID), CreatedAt: createdAt, UpdatedAt: createdAt}})
}

// recordSessionUpdate submits a session update for engine-side derivation and
// reports whether the engine accepted it (appended an event); a stale update is
// dropped and returns false.
func (i *ProviderRuntimeIngestion) recordSessionUpdate(threadID string, update sessionUpdate, createdAt time.Time) bool {
	update.threadID = ThreadID(threadID)
	update.occurredAt = createdAt
	result, err := i.engine.updateSession(context.Background(), update)
	if err != nil {
		select {
		case <-i.engine.closed:
			return false // normal teardown; there is no consumer to diagnose or unblock
		default:
		}
		log.Printf("orchestration: failed to apply session update %q for thread %q: %v", update.Kind, threadID, err)
		return false
	}
	return result.Sequence != 0
}

func reasoningStatusFromTurnState(state provider.RuntimeTurnState) provider.ItemStatus {
	switch state {
	case provider.RuntimeTurnFailed:
		return provider.ItemStatusFailed
	case provider.RuntimeTurnInterrupted, provider.RuntimeTurnCancelled:
		return provider.ItemStatusInterrupted
	default:
		return provider.ItemStatusCompleted
	}
}

func itemStatusOr(s provider.ItemStatus, fallback provider.ItemStatus) provider.ItemStatus {
	if s == "" {
		return fallback
	}
	return s
}

// approvalDecisionOrCancel normalizes an adapter-reported decision: anything
// but an explicit accept/decline (including empty) resolves as cancel.
func approvalDecisionOrCancel(decision provider.ApprovalDecision) provider.ApprovalDecision {
	switch decision {
	case provider.ApprovalDecisionAccept, provider.ApprovalDecisionAcceptForSession, provider.ApprovalDecisionDecline:
		return decision
	default:
		return provider.ApprovalDecisionCancel
	}
}

func optionIDFromResolution(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var payload struct {
		OptionID string `json:"optionId"`
	}
	_ = json.Unmarshal(raw, &payload)
	return payload.OptionID
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
