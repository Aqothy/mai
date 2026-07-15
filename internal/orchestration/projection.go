package orchestration

import (
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

type Projection struct {
	threads         map[ThreadID]*Thread
	createSequences map[ThreadID]uint64
	sequence        uint64
	updatedAt       time.Time
}

func NewProjection() *Projection {
	return &Projection{threads: make(map[ThreadID]*Thread), createSequences: make(map[ThreadID]uint64)}
}

func (p *Projection) Apply(event Event) {
	if event.Sequence > p.sequence {
		p.sequence = event.Sequence
	}
	if p.updatedAt.IsZero() || event.OccurredAt.After(p.updatedAt) {
		p.updatedAt = event.OccurredAt
	}
	switch event.Type {
	case EventThreadCreated:
		p.applyThreadCreated(event)
	case EventThreadMetaUpdated:
		p.applyThreadMetaUpdated(event)
	case EventThreadSessionStatusSet:
		p.applyThreadSessionStatusSet(event)
	case EventThreadHistoryReplayCompleted:
		p.applyThreadHistoryReplayCompleted(event)
	case EventThreadMessageSent:
		p.applyThreadMessageSent(event)
	case EventThreadTurnStartRequested:
		p.applyThreadTurnStartRequested(event)
	case EventThreadTurnInterruptRequested:
		p.applyThreadTurnInterruptRequested(event)
	case EventThreadTurnInterruptConfirmed:
		p.applyThreadTurnInterruptConfirmed(event)
	case EventThreadTurnInterruptFailed:
		p.applyThreadTurnInterruptFailed(event)
	case EventThreadSessionPrepareRequested:
		p.applyThreadSessionPrepareRequested(event)
	case EventThreadSessionStopRequested:
		p.applyThreadSessionStopRequested(event)
	case EventThreadSessionStopFailed:
		p.applyThreadSessionStopFailed(event)
	case EventThreadApprovalResponseRequested:
		p.applyThreadApprovalResponseRequested(event)
	case EventThreadItemUpserted:
		p.applyThreadItemUpserted(event)
	case EventThreadPlanUpdated:
		p.applyThreadPlanUpdated(event)
	case EventThreadApprovalOpened:
		p.applyThreadApprovalOpened(event)
	case EventThreadApprovalResolved:
		p.applyThreadApprovalResolved(event)
	case EventThreadConfigOptionsUpdated:
		p.applyThreadConfigOptionsUpdated(event)
	case EventThreadSlashCommandsUpdated:
		p.applyThreadSlashCommandsUpdated(event)
	case EventThreadTokenUsageUpdated:
		p.applyThreadTokenUsageUpdated(event)
	}
}

func (p *Projection) Thread(id ThreadID) (Thread, bool) {
	thread := p.threads[id]
	if thread == nil {
		return Thread{}, false
	}
	return cloneThread(*thread), true
}

func (p *Projection) ThreadListEntry(id ThreadID) (ThreadListEntry, bool) {
	thread := p.threads[id]
	if thread == nil {
		return ThreadListEntry{}, false
	}
	// The caller holds the engine lock. Build only the sidebar projection instead
	// of deep-cloning the full message/item history first.
	return threadListEntryFromThread(*thread), true
}

func (p *Projection) ThreadListSnapshot() ThreadListSnapshot {
	threads := make([]ThreadListEntry, 0, len(p.threads))
	for _, thread := range p.threads {
		threads = append(threads, threadListEntryFromThread(*thread))
	}
	sort.Slice(threads, func(i, j int) bool { return threads[i].UpdatedAt.After(threads[j].UpdatedAt) })
	updatedAt := p.updatedAt
	if updatedAt.IsZero() {
		updatedAt = time.Now()
	}
	return ThreadListSnapshot{SnapshotSequence: p.sequence, Threads: threads, UpdatedAt: updatedAt}
}

func (p *Projection) ThreadSnapshot(id ThreadID) (ThreadDetailSnapshot, error) {
	thread, ok := p.Thread(id)
	if !ok {
		return ThreadDetailSnapshot{}, fmt.Errorf("thread %q not found", id)
	}
	return ThreadDetailSnapshot{SnapshotSequence: p.sequence, Thread: thread}, nil
}

// liveThread returns the projection's own mutable *Thread (nil if absent) for
// clone-free reads on the engine's hot paths.
func (p *Projection) liveThread(id ThreadID) *Thread { return p.threads[id] }

func (p *Projection) createSequence(id ThreadID) uint64 { return p.createSequences[id] }

func (p *Projection) appliedSequence() uint64 { return p.sequence }

func (p *Projection) applyThreadCreated(event Event) {
	payload := event.Payload
	threadID := payload.ThreadID
	if threadID == "" {
		return
	}
	if p.threads[threadID] != nil {
		return
	}
	title := payload.Title
	if title == "" {
		title = "Untitled thread"
	}
	if p.createSequences == nil {
		p.createSequences = make(map[ThreadID]uint64)
	}
	if _, ok := p.createSequences[threadID]; !ok {
		p.createSequences[threadID] = event.Sequence
	}
	p.threads[threadID] = &Thread{
		ID:                 threadID,
		Draft:              true,
		Title:              title,
		ProviderInstanceID: payload.ProviderInstanceID,
		ModelSelection:     cloneModelSelection(payload.ModelSelection),
		Cwd:                payload.Cwd,
		Timeline:           Timeline{},
		CreatedAt:          event.OccurredAt,
		UpdatedAt:          event.OccurredAt,
	}
}

func (p *Projection) applyThreadMetaUpdated(event Event) {
	thread := p.ensureThread(event)
	if thread == nil {
		return
	}
	payload := event.Payload
	if payload.Title != "" {
		thread.Title = payload.Title
	}
	applyThreadProviderSelectionPatch(thread, payload.ProviderInstanceID, payload.ModelSelection, payload.SessionCleared)
	if payload.Cwd != "" {
		thread.Cwd = payload.Cwd
	}
}

// applyThreadSessionStatusSet REPLACES the thread's session binding: the
// payload is complete and current by construction — the engine derives it
// from the live thread for session updates, and direct appenders own their full
// payload. No field-by-field merge happens here.
func (p *Projection) applyThreadSessionStatusSet(event Event) {
	thread := p.ensureThread(event)
	if thread == nil || event.Payload.Session == nil || event.Payload.Session.Status == "" {
		return
	}
	session := cloneSessionPtr(event.Payload.Session)
	session.ThreadID = thread.ID
	session.StopRequested = false // any recorded status resolves a pending stop intent
	if session.Status != SessionStatusError {
		session.LastError = ""
	}
	session.UpdatedAt = event.OccurredAt
	thread.Session = session
	p.applySessionBindingFields(thread, session)
	p.applySessionTurnState(thread, session, event.Payload.StopReason, event.OccurredAt)
}

func (p *Projection) applyThreadHistoryReplayCompleted(event Event) {
	if thread := p.threads[event.ThreadID()]; thread != nil {
		thread.ReplayHistoryPending = false
	}
}

func (p *Projection) applySessionBindingFields(thread *Thread, session *SessionBinding) {
	if session.ProviderInstanceID != "" && thread.ProviderInstanceID == "" {
		// Backfill the identity of a thread whose first binding arrived before
		// any client-selected instance; the model choice is untouched.
		thread.ProviderInstanceID = session.ProviderInstanceID
	}
	if thread.Cwd == "" {
		thread.Cwd = session.Cwd
	}
}

func (p *Projection) applySessionTurnState(thread *Thread, session *SessionBinding, stopReason string, occurredAt time.Time) {
	if session.ActiveTurnID != "" {
		if thread.LatestTurn == nil || thread.LatestTurn.ID != session.ActiveTurnID {
			thread.LatestTurn = &Turn{ID: session.ActiveTurnID, State: TurnStateRunning, RequestedAt: occurredAt, StartedAt: &occurredAt}
			return
		}
		thread.LatestTurn.State = TurnStateRunning
		return
	}
	if thread.LatestTurn == nil || thread.LatestTurn.CompletedAt != nil {
		return
	}
	completed := occurredAt
	thread.LatestTurn.InterruptRequested = false
	thread.LatestTurn.StopReason = stopReason
	switch session.Status {
	case SessionStatusError:
		thread.LatestTurn.State = TurnStateError
		thread.LatestTurn.Error = session.LastError
	case SessionStatusInterrupted, SessionStatusStopped:
		thread.LatestTurn.State = TurnStateInterrupted
	default:
		thread.LatestTurn.State = TurnStateCompleted
	}
	thread.LatestTurn.CompletedAt = &completed
}

func (p *Projection) applyThreadMessageSent(event Event) {
	thread := p.ensureThread(event)
	if thread == nil || event.Payload.MessageID == "" {
		return
	}
	message := Message{ID: event.Payload.MessageID, Role: event.Payload.Role, Text: event.Payload.Text, Attachments: event.Payload.Attachments, TurnID: event.Payload.TurnID, CreatedAt: firstTime(event.Payload.CreatedAt, event.OccurredAt), UpdatedAt: firstTime(event.Payload.UpdatedAt, event.OccurredAt)}
	if existing := thread.Timeline.Message(message.ID); existing != nil {
		existing.Text += message.Text
		existing.Attachments = append(existing.Attachments, message.Attachments...)
		if message.TurnID != "" {
			existing.TurnID = message.TurnID
		}
		existing.UpdatedAt = event.OccurredAt
	} else {
		thread.Timeline.AppendMessage(message)
	}
	if message.Role == MessageRoleUser && !thread.ReplayHistoryPending && event.OccurredAt.After(thread.UpdatedAt) {
		thread.UpdatedAt = event.OccurredAt
	}
}

func (p *Projection) applyThreadTurnStartRequested(event Event) {
	thread := p.ensureThread(event)
	if thread == nil {
		return
	}
	applyThreadProviderSelectionPatch(thread, event.Payload.ProviderInstanceID, event.Payload.ModelSelection, event.Payload.SessionCleared)
	if thread.Draft {
		thread.Draft = false
		if event.Payload.Title != "" {
			thread.Title = event.Payload.Title
		}
	}
	now := event.OccurredAt
	turnID := event.Payload.TurnID
	if turnID == "" {
		turnID = TurnID(event.EventID)
	}
	// A turn.start for the already-running turn is steering: the same logical
	// turn keeps going, so its RequestedAt/StartedAt must survive.
	if thread.LatestTurn == nil || thread.LatestTurn.ID != turnID {
		thread.LatestTurn = &Turn{ID: turnID, State: TurnStateRunning, RequestedAt: now, StartedAt: &now}
	}
	// A server-requeued start moves an already-recorded steering message onto a
	// fresh turn after the old turn won the completion race.
	if event.Payload.MessageID != "" {
		if message := thread.Timeline.Message(event.Payload.MessageID); message != nil {
			message.TurnID = turnID
		}
	}
	if thread.Session != nil {
		thread.Session.Status = SessionStatusRunning
		thread.Session.ActiveTurnID = turnID
		thread.Session.UpdatedAt = event.OccurredAt
	}
}

func (p *Projection) applyThreadTurnInterruptRequested(event Event) {
	thread := p.ensureThread(event)
	if thread == nil || !interruptTargetsActiveTurn(thread, event.Payload.TurnID) {
		return
	}
	// This event records client intent only. The provider's turn/session event is
	// authoritative, because cancellation can fail or completion can win the race.
	if thread.LatestTurn != nil {
		thread.LatestTurn.InterruptRequested = true
	}
}

func (p *Projection) applyThreadTurnInterruptConfirmed(event Event) {
	thread := p.ensureThread(event)
	if thread == nil || thread.LatestTurn == nil || thread.LatestTurn.ID != event.Payload.TurnID || thread.LatestTurn.CompletedAt != nil {
		return
	}
	completed := event.OccurredAt
	thread.LatestTurn.State = TurnStateInterrupted
	thread.LatestTurn.InterruptRequested = false
	thread.LatestTurn.CompletedAt = &completed
}

func (p *Projection) applyThreadTurnInterruptFailed(event Event) {
	thread := p.ensureThread(event)
	if thread == nil || thread.LatestTurn == nil || thread.LatestTurn.ID != event.Payload.TurnID || thread.LatestTurn.CompletedAt != nil {
		return
	}
	thread.LatestTurn.InterruptRequested = false
}

func (p *Projection) applyThreadSessionStopRequested(event Event) {
	thread := p.ensureThread(event)
	if thread == nil || thread.Session == nil {
		return
	}
	// Stop is confirmed by EventThreadSessionStatusSet from the reactor. Keeping
	// the current binding here prevents a failed provider RPC from lying about
	// session and turn completion.
	thread.Session.StopRequested = true
}

func (p *Projection) applyThreadSessionStopFailed(event Event) {
	thread := p.ensureThread(event)
	if thread == nil || thread.Session == nil {
		return
	}
	thread.Session.StopRequested = false
}

func (p *Projection) applyThreadApprovalResponseRequested(event Event) {
	thread := p.ensureThread(event)
	if thread == nil {
		return
	}
	if approval := thread.Timeline.Approval(string(event.Payload.RequestID)); approval != nil {
		approval.Decision = event.Payload.Decision
		approval.OptionID = event.Payload.OptionID
		approval.UpdatedAt = event.OccurredAt
	}
}

func (p *Projection) applyThreadItemUpserted(event Event) {
	thread := p.ensureThread(event)
	if thread == nil || event.Payload.Item == nil {
		return
	}
	item := *event.Payload.Item
	item.UpdatedAt = event.OccurredAt
	if item.CreatedAt.IsZero() {
		item.CreatedAt = event.OccurredAt
	}
	if existing := thread.Timeline.Item(item.ID); existing != nil {
		if item.Kind == "" {
			item.Kind = existing.Kind
		}
		if item.Title == "" {
			item.Title = existing.Title
		}
		if item.Status == "" {
			item.Status = existing.Status
		}
		item.Payload = applyItemPayload(existing.Payload, item.Payload, item.TextDelta)
		item.TextDelta = ""
		if item.TurnID == "" {
			item.TurnID = existing.TurnID
		}
		item.CreatedAt = existing.CreatedAt
		*existing = item
		return
	}
	if item.Status == "" {
		item.Status = provider.ItemStatusInProgress
	}
	item.Payload = applyItemPayload(nil, item.Payload, item.TextDelta)
	item.TextDelta = ""
	thread.Timeline.AppendItem(item)
}

func (p *Projection) applyThreadPlanUpdated(event Event) {
	thread := p.ensureThread(event)
	if thread == nil || event.Payload.Plan == nil {
		return
	}
	plan := *event.Payload.Plan
	plan.Entries = append([]provider.PlanEntry(nil), plan.Entries...)
	plan.UpdatedAt = event.OccurredAt
	thread.Plan = &plan
}

func (p *Projection) applyThreadApprovalOpened(event Event) {
	thread := p.ensureThread(event)
	if thread == nil || event.Payload.Approval == nil {
		return
	}
	approval := event.Payload.Approval
	if existing := thread.Timeline.Approval(approval.RequestID); existing != nil {
		existing.TurnID = approval.TurnID
		existing.Args = append(json.RawMessage(nil), approval.Args...)
		existing.Options = approval.Options
		existing.Status = ApprovalStatusPending
		existing.Decision = ""
		existing.OptionID = ""
		existing.UpdatedAt = event.OccurredAt
		return
	}
	value := Approval{RequestID: approval.RequestID, TurnID: approval.TurnID, Args: append(json.RawMessage(nil), approval.Args...), Options: approval.Options, Status: ApprovalStatusPending, CreatedAt: event.OccurredAt, UpdatedAt: event.OccurredAt}
	thread.Timeline.AppendApproval(value)
}

func (p *Projection) applyThreadApprovalResolved(event Event) {
	thread := p.ensureThread(event)
	if thread == nil || event.Payload.Approval == nil {
		return
	}
	approval := event.Payload.Approval
	if existing := thread.Timeline.Approval(approval.RequestID); existing != nil {
		existing.Status = ApprovalStatusResolved
		existing.Decision = approval.Decision
		existing.OptionID = approval.OptionID
		existing.UpdatedAt = event.OccurredAt
		return
	}
	value := Approval{RequestID: approval.RequestID, TurnID: approval.TurnID, Status: ApprovalStatusResolved, Decision: approval.Decision, OptionID: approval.OptionID, CreatedAt: event.OccurredAt, UpdatedAt: event.OccurredAt}
	thread.Timeline.AppendApproval(value)
}

func (p *Projection) applyThreadConfigOptionsUpdated(event Event) {
	thread := p.ensureThread(event)
	if thread == nil {
		return
	}
	session := ensureSessionBinding(thread, event)
	session.ConfigOptions = cloneConfigOptions(event.Payload.ConfigOptions)
	if event.Payload.ModelSelection != nil {
		thread.ModelSelection = cloneModelSelection(event.Payload.ModelSelection)
	}
	session.UpdatedAt = event.OccurredAt
}

func (p *Projection) applyThreadSlashCommandsUpdated(event Event) {
	thread := p.ensureThread(event)
	if thread == nil {
		return
	}
	session := ensureSessionBinding(thread, event)
	session.SlashCommands = cloneSlashCommands(event.Payload.SlashCommands)
	session.UpdatedAt = event.OccurredAt
}

func (p *Projection) applyThreadTokenUsageUpdated(event Event) {
	thread := p.ensureThread(event)
	if thread == nil {
		return
	}
	session := ensureSessionBinding(thread, event)
	if event.Payload.TokenUsage != nil {
		usage := *event.Payload.TokenUsage
		session.TokenUsage = &usage
	} else {
		session.TokenUsage = nil
	}
	session.UpdatedAt = event.OccurredAt
}

func (p *Projection) ensureThread(event Event) *Thread {
	threadID := event.ThreadID()
	if threadID == "" {
		return nil
	}
	thread := p.threads[threadID]
	if thread != nil {
		return thread
	}
	p.applyThreadCreated(Event{OccurredAt: event.OccurredAt, Payload: EventPayload{ThreadID: threadID, Title: "Untitled thread"}})
	return p.threads[threadID]
}

func (p *Projection) applyThreadSessionPrepareRequested(event Event) {
	thread := p.ensureThread(event)
	if thread == nil {
		return
	}
	session := ensureSessionBinding(thread, event)
	session.Status = SessionStatusStarting
	session.ActiveTurnID = ""
	session.LastError = ""
	session.UpdatedAt = event.OccurredAt
}

func ensureSessionBinding(thread *Thread, event Event) *SessionBinding {
	if thread.Session != nil {
		return thread.Session
	}
	providerInstanceID := event.Payload.ProviderInstanceID
	if providerInstanceID == "" {
		providerInstanceID = thread.ProviderInstanceID
	}
	thread.Session = &SessionBinding{ThreadID: thread.ID, ProviderInstanceID: providerInstanceID, Cwd: thread.Cwd, Status: SessionStatusStarting, UpdatedAt: event.OccurredAt}
	return thread.Session
}

func interruptTargetsActiveTurn(thread *Thread, turnID TurnID) bool {
	if turnID == "" {
		return activeTurnID(*thread) != ""
	}
	return activeTurnID(*thread) == turnID
}

// applyItemPayload implements the two item-payload rules clients must mirror
// (CLIENT_API §5):
//   - textDelta (coalesced reasoning chunk): append it to the payload's
//     "text" — events stay O(chunk) instead of re-sending accumulated text;
//   - otherwise a non-empty payload REPLACES the previous one (producers send
//     the complete payload — the ACP adapter accumulates sparse tool-call
//     updates itself), and an absent payload keeps it.
func applyItemPayload(existing json.RawMessage, incoming json.RawMessage, textDelta string) json.RawMessage {
	if textDelta != "" {
		return appendPayloadText(existing, textDelta)
	}
	if len(incoming) > 0 {
		return cloneRawMessage(incoming)
	}
	return cloneRawMessage(existing)
}

// appendPayloadText appends a flushed chunk to the payload's "text"; an
// unparseable base keeps the accumulated payload rather than resetting the
// text to one chunk.
func appendPayloadText(existing json.RawMessage, delta string) json.RawMessage {
	var base reasoningPayload
	if len(existing) > 0 {
		if err := json.Unmarshal(existing, &base); err != nil {
			return cloneRawMessage(existing)
		}
	}
	base.Text += delta
	return marshalEventPayload(base)
}

// ThreadListVisible reports whether an event changes state presented in the
// thread-list/sidebar: identity, activity time, live run/stop/interrupt state,
// or pending approvals. Conversation-detail state is intentionally excluded.
func ThreadListVisible(event Event) bool {
	switch event.Type {
	case EventThreadCreated,
		EventThreadMetaUpdated,
		EventThreadTurnStartRequested,
		EventThreadTurnInterruptConfirmed,
		EventThreadSessionPrepareRequested,
		EventThreadSessionStatusSet,
		EventThreadApprovalOpened,
		EventThreadApprovalResolved:
		return true
	case EventThreadMessageSent:
		return event.Payload.Role == MessageRoleUser
	default:
		return false
	}
}

// ThreadMetadataMayChange reports whether an event can alter metadata stored in
// the threads table. It is intentionally separate from ThreadListVisible:
// session and approval state belong in the live sidebar but not in that table.
func ThreadMetadataMayChange(event Event) bool {
	switch event.Type {
	case EventThreadMetaUpdated:
		return true
	case EventThreadMessageSent:
		return event.Payload.Role == MessageRoleUser
	case EventThreadConfigOptionsUpdated:
		return event.Payload.ModelSelection != nil
	default:
		return false
	}
}

func threadListEntryFromThread(thread Thread) ThreadListEntry {
	pendingApprovals := false
	for _, entry := range thread.Timeline {
		if approval := entry.Approval; approval != nil && approval.Status == ApprovalStatusPending {
			pendingApprovals = true
		}
	}
	return ThreadListEntry{ID: thread.ID, Draft: thread.Draft, Title: thread.Title, ProviderInstanceID: thread.ProviderInstanceID, ModelSelection: cloneModelSelection(thread.ModelSelection), Cwd: thread.Cwd, LatestTurn: cloneTurnPtr(thread.LatestTurn), CreatedAt: thread.CreatedAt, UpdatedAt: thread.UpdatedAt, Session: cloneSessionPtr(thread.Session), HasPendingApprovals: pendingApprovals}
}
