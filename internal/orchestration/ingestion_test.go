package orchestration

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// pinFlushInterval overrides the shared text-flush ticker cadence.
func pinFlushInterval(t *testing.T, interval time.Duration) {
	t.Helper()
	previous := textFlushInterval
	textFlushInterval = interval
	t.Cleanup(func() { textFlushInterval = previous })
}

func waitFor(t *testing.T, desc string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", desc)
}

func runIngestion(t *testing.T, ingestion *ProviderRuntimeIngestion) chan<- provider.RuntimeEvent {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	events := make(chan provider.RuntimeEvent, 16)
	go ingestion.Run(ctx, events)
	t.Cleanup(cancel)
	return events
}

func newThreadWithSession(t *testing.T, engine *Engine, threadID ThreadID) {
	t.Helper()
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: CommandID("create-" + string(threadID)), ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"})
	binding := &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusReady, UpdatedAt: time.Now()}
	mustAppend(t, engine, EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: binding}})
}

func TestRestoreHistoryDoesNotBlockOtherThreads(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	events := observeEvents(t, engine)
	ingestion := NewProviderRuntimeIngestion(engine)
	now := time.Now()
	engine.RestoreThreads([]RestoredThread{
		{ThreadID: "restoring", ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now},
		{ThreadID: "active", ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now},
	})

	loadEntered := make(chan struct{})
	releaseLoad := make(chan struct{})
	readyEntered := make(chan struct{})
	releaseReady := make(chan struct{})
	restoreDone := make(chan error, 1)
	go func() {
		restoreDone <- ingestion.RestoreHistory("restoring", func() (provider.StartSessionResult, error) {
			close(loadEntered)
			<-releaseLoad
			return provider.StartSessionResult{
				Session: provider.Session{ThreadID: "restoring", ProviderInstanceID: "codex"},
				Replay: []provider.RuntimeEvent{{
					Type:     provider.RuntimeEventContentDelta,
					ThreadID: "restoring",
					Payload:  provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "restored answer"},
				}},
			}, nil
		}, func(session provider.Session) {
			binding := bindingFromProviderSession("codex", session)
			binding.Status = SessionStatusReady
			if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: "restoring", Payload: EventPayload{Session: &binding}}); err != nil {
				t.Errorf("record ready session: %v", err)
			}
			close(readyEntered)
			<-releaseReady
		})
	}()
	<-loadEntered

	otherThreadDone := make(chan struct{})
	go func() {
		ingestion.Ingest(provider.RuntimeEvent{Type: provider.RuntimeEventRuntimeWarning, ThreadID: "active", Payload: provider.RuntimeEventPayload{Message: "other warning"}})
		close(otherThreadDone)
	}()

	select {
	case <-otherThreadDone:
	case <-time.After(time.Second):
		t.Fatal("unrelated thread was blocked by provider load")
	}
	ingestion.Ingest(provider.RuntimeEvent{Type: provider.RuntimeEventRuntimeWarning, ThreadID: "restoring", Payload: provider.RuntimeEventPayload{Message: "live warning"}})

	close(releaseLoad)
	<-readyEntered
	commitOtherDone := make(chan struct{})
	go func() {
		ingestion.Ingest(provider.RuntimeEvent{Type: provider.RuntimeEventRuntimeWarning, ThreadID: "active", Payload: provider.RuntimeEventPayload{Message: "other commit warning"}})
		close(commitOtherDone)
	}()
	select {
	case <-commitOtherDone:
	case <-time.After(time.Second):
		t.Fatal("unrelated thread was blocked by ready handoff")
	}
	afterReadyDone := make(chan struct{})
	go func() {
		ingestion.Ingest(provider.RuntimeEvent{Type: provider.RuntimeEventRuntimeWarning, ThreadID: "restoring", Payload: provider.RuntimeEventPayload{Message: "after ready"}})
		close(afterReadyDone)
	}()
	select {
	case <-afterReadyDone:
		t.Fatal("same-thread event crossed the ready handoff")
	case <-time.After(20 * time.Millisecond):
	}

	close(releaseReady)
	if err := <-restoreDone; err != nil {
		t.Fatalf("RestoreHistory: %v", err)
	}
	select {
	case <-afterReadyDone:
	case <-time.After(time.Second):
		t.Fatal("same-thread event remained blocked after ready")
	}

	recorded := events.matching("restoring", 0)
	var messageSequence, queuedSequence, completionSequence, readySequence, afterReadySequence uint64
	for _, event := range recorded {
		switch event.Type {
		case EventThreadMessageSent:
			messageSequence = event.Sequence
		case EventThreadHistoryReplayCompleted:
			completionSequence = event.Sequence
		case EventThreadSessionStatusSet:
			readySequence = event.Sequence
		case EventThreadItemUpserted:
			if event.Payload.Item != nil && event.Payload.Item.Title == "live warning" {
				queuedSequence = event.Sequence
			} else if event.Payload.Item != nil && event.Payload.Item.Title == "after ready" {
				afterReadySequence = event.Sequence
			}
		}
	}
	if messageSequence == 0 || !(messageSequence < queuedSequence && queuedSequence < completionSequence && completionSequence < readySequence && readySequence < afterReadySequence) {
		t.Fatalf("message/queued/completion/ready/after sequences = %d/%d/%d/%d/%d", messageSequence, queuedSequence, completionSequence, readySequence, afterReadySequence)
	}
}

func TestTickerDoesNotFlushThreadDuringHistoryReplay(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("restoring")
	now := time.Now()
	engine.RestoreThreads([]RestoredThread{{ThreadID: threadID, ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now}})

	gate := &historyReplayGate{}
	ingestion.replayMu.Lock()
	ingestion.replaying[string(threadID)] = gate
	ingestion.replayMu.Unlock()
	ingestion.ingest(provider.RuntimeEvent{
		Type:     provider.RuntimeEventContentDelta,
		ThreadID: string(threadID),
		Payload:  provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "restored answer"},
	})
	ingestion.flushPendingText(time.Now())
	thread, _ := engine.Thread(threadID)
	if len(thread.Timeline) != 0 {
		t.Fatalf("ticker exposed partial replay: %#v", thread.Timeline)
	}

	ingestion.completeHistoryReplay(string(threadID), nil)
	gate.mu.Lock()
	gate.closed = true
	gate.mu.Unlock()
	ingestion.replayMu.Lock()
	delete(ingestion.replaying, string(threadID))
	ingestion.replayMu.Unlock()
	thread, _ = engine.Thread(threadID)
	if len(thread.Timeline) != 1 || thread.Timeline[0].Message == nil || thread.Timeline[0].Message.Text != "restored answer" {
		t.Fatalf("completed replay timeline = %#v, want restored answer", thread.Timeline)
	}
}

func TestIngestionProjectsProviderApprovalResolution(t *testing.T) {
	tests := []struct {
		name       string
		decision   provider.ApprovalDecision
		resolution json.RawMessage
		want       provider.ApprovalDecision
		wantOption string
	}{
		{name: "accept", decision: provider.ApprovalDecisionAccept, resolution: json.RawMessage(`{"optionId":"allow"}`), want: provider.ApprovalDecisionAccept, wantOption: "allow"},
		{name: "accept for session", decision: provider.ApprovalDecisionAcceptForSession, resolution: json.RawMessage(`{"optionId":"session"}`), want: provider.ApprovalDecisionAcceptForSession, wantOption: "session"},
		{name: "decline", decision: provider.ApprovalDecisionDecline, resolution: json.RawMessage(`{"optionId":"reject"}`), want: provider.ApprovalDecisionDecline, wantOption: "reject"},
		{name: "empty defaults to cancel", want: provider.ApprovalDecisionCancel},
		{name: "unknown defaults to cancel", decision: provider.ApprovalDecision("unknown"), resolution: json.RawMessage(`not-json`), want: provider.ApprovalDecisionCancel},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			engine := NewEngine()
			defer engine.Close()
			ingestion := NewProviderRuntimeIngestion(engine)
			threadID := ThreadID("thread-resolved-" + strings.ReplaceAll(tt.name, " ", "-"))
			newThreadWithSession(t, engine, threadID)

			ingestion.Ingest(provider.RuntimeEvent{
				EventID:   "approval-opened",
				Type:      provider.RuntimeEventRequestOpened,
				ThreadID:  string(threadID),
				TurnID:    "turn-1",
				RequestID: "approval-1",
				Payload: provider.RuntimeEventPayload{
					RequestType: provider.RuntimeRequestCommandExecution,
					Options:     []provider.ApprovalOption{{ID: "allow"}, {ID: "session"}, {ID: "reject"}},
				},
			})
			thread, _ := engine.Thread(threadID)
			if len(thread.Timeline) != 1 || thread.Timeline[0].Approval == nil {
				t.Fatalf("timeline after open = %#v, want one approval", thread.Timeline)
			}
			createdAt := thread.Timeline[0].Approval.CreatedAt

			ingestion.Ingest(provider.RuntimeEvent{
				EventID:   "approval-resolved",
				Type:      provider.RuntimeEventRequestResolved,
				ThreadID:  string(threadID),
				TurnID:    "turn-1",
				RequestID: "approval-1",
				Payload: provider.RuntimeEventPayload{
					RequestType: provider.RuntimeRequestCommandExecution,
					Decision:    tt.decision,
					Resolution:  tt.resolution,
				},
			})

			thread, _ = engine.Thread(threadID)
			if len(thread.Timeline) != 1 || thread.Timeline[0].Approval == nil {
				t.Fatalf("timeline after resolve = %#v, want the original approval in place", thread.Timeline)
			}
			approval := thread.Timeline[0].Approval
			if approval.Status != ApprovalStatusResolved || approval.Decision != tt.want || approval.OptionID != tt.wantOption {
				t.Fatalf("resolved approval = %#v, want decision=%q option=%q", approval, tt.want, tt.wantOption)
			}
			if !approval.CreatedAt.Equal(createdAt) {
				t.Fatalf("resolved approval moved/recreated: createdAt=%v, want %v", approval.CreatedAt, createdAt)
			}
		})
	}
}

func TestIngestionPreservesRestoredThreadRecencyDuringReplay(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-replayed-recency")
	restoredAt := time.Now().Add(-24 * time.Hour).UTC()
	replayedAt := restoredAt.Add(2 * time.Hour)
	engine.RestoreThreads([]RestoredThread{{ThreadID: threadID, ProviderInstanceID: "codex", CreatedAt: restoredAt, UpdatedAt: restoredAt}})

	ingestion.Ingest(provider.RuntimeEvent{
		EventID:   "replayed-user",
		Type:      provider.RuntimeEventItemCompleted,
		ThreadID:  string(threadID),
		ItemID:    "replayed-user",
		CreatedAt: replayedAt,
		Payload: provider.RuntimeEventPayload{
			ItemType: provider.ItemKindUserMessage,
			Detail:   "old question",
		},
	})

	thread, _ := engine.Thread(threadID)
	if !thread.UpdatedAt.Equal(restoredAt) {
		t.Fatalf("replay changed restored recency to %v, want %v", thread.UpdatedAt, restoredAt)
	}

	ingestion.completeHistoryReplay(string(threadID), nil)
	thread, _ = engine.Thread(threadID)
	if !thread.UpdatedAt.Equal(restoredAt) {
		t.Fatalf("replay completion changed restored recency to %v, want %v", thread.UpdatedAt, restoredAt)
	}

	liveAt := replayedAt.Add(2 * time.Minute)
	if _, err := engine.AppendEvent(context.Background(), EventInput{
		Type:       EventThreadMessageSent,
		ThreadID:   threadID,
		Actor:      ActorKindClient,
		OccurredAt: liveAt,
		Payload: EventPayload{
			MessageID: "live-user",
			Role:      MessageRoleUser,
			Text:      "new question",
		},
	}); err != nil {
		t.Fatalf("append live user message: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	if !thread.UpdatedAt.Equal(liveAt) {
		t.Fatalf("live message left recency at %v, want %v", thread.UpdatedAt, liveAt)
	}
}

func TestIngestionDropsRuntimeEventsFromStaleProviderInstance(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-stale-provider-event")
	newThreadWithSession(t, engine, threadID)

	ingestTitle := func(instance provider.InstanceID, title, want string) {
		t.Helper()
		ingestion.Ingest(provider.RuntimeEvent{EventID: provider.RuntimeEventID("evt-" + title), Type: provider.RuntimeEventThreadMetadataUpdate, Provider: "test", ProviderInstanceID: instance, ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Title: title}})
		if thread, ok := engine.Thread(threadID); !ok || thread.Title != want {
			t.Fatalf("title after %q from %q = %q, want %q", title, instance, thread.Title, want)
		}
	}
	ingestTitle("old-instance", "stale title", "Thread")
	ingestTitle("codex", "current title", "current title")

	// After a provider switch the desired instance is authoritative even before
	// the new session binds, and the stale binding is cleared.
	mustDispatch(t, engine, Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-switch-provider-for-stale-event", ThreadID: threadID, ProviderInstanceID: "new-instance"})
	if thread, _ := engine.Thread(threadID); thread.Session != nil {
		t.Fatalf("session after provider switch = %#v, want stale binding cleared", thread.Session)
	}
	ingestTitle("codex", "old before rebind", "current title")
	ingestTitle("new-instance", "new before rebind", "new before rebind")

	mustAppend(t, engine, EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "new-instance", Status: SessionStatusReady, UpdatedAt: time.Now()}}})
	ingestTitle("codex", "late old title", "new before rebind")
	ingestTitle("new-instance", "new title", "new title")
}

func TestIngestionDropsTerminalEventFromReplacedGenerationAfterRebind(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-stale-provider-generation")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "create-stale-provider-generation", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"})
	mustAppend(t, engine, EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", ProviderGeneration: 2, Status: SessionStatusRunning, ActiveTurnID: "turn-1", UpdatedAt: time.Now()}}})

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-old-terminal", Type: provider.RuntimeEventTurnCompleted, Provider: "test", ProviderInstanceID: "codex", Generation: 1, ThreadID: string(threadID), TurnID: "turn-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnFailed, Message: "old process failed"}})

	thread, ok := engine.Thread(threadID)
	if !ok || thread.Session == nil {
		t.Fatalf("thread/session missing: %#v", thread)
	}
	if thread.Session.Status != SessionStatusRunning || thread.Session.ActiveTurnID != "turn-1" {
		t.Fatalf("session after stale terminal = %#v, want replacement generation still running", thread.Session)
	}
	if len(thread.Timeline.Items()) != 0 {
		t.Fatalf("items after stale terminal = %#v, want no old-generation error", thread.Timeline.Items())
	}
}

// A provider pause must not hide buffered text: one ticker pass flushes every
// active assistant and reasoning stream, across threads.
func TestIngestionTickerFlushesBufferedTextAcrossThreads(t *testing.T) {
	pinFlushInterval(t, 20*time.Millisecond)
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	events := runIngestion(t, ingestion)

	want := map[ThreadID]string{"thread-ticker-a": "assistant:", "thread-ticker-b": "assistant:", "thread-ticker-reasoning": "reasoning(in_progress):"}
	for threadID, prefix := range want {
		newThreadWithSession(t, engine, threadID)
		kind := provider.RuntimeContentAssistantText
		if strings.HasPrefix(prefix, "reasoning") {
			kind = provider.RuntimeContentReasoningText
		}
		for _, delta := range []string{"hello ", string(threadID)} {
			events <- provider.RuntimeEvent{Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: "turn-1", ItemID: "stream-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: kind, Delta: delta}}
		}
	}

	waitFor(t, "a ticker flush of every active stream", func() bool {
		for threadID, prefix := range want {
			thread, _ := engine.Thread(threadID)
			if got := describeTimeline(thread.Timeline); len(got) != 1 || got[0] != prefix+"hello "+string(threadID) {
				return false
			}
		}
		return true
	})
}

func TestIngestionPlanUpdatedProjectsPlan(t *testing.T) {
	engine := NewEngine()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-plan")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "create-plan", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"})

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-plan", Type: provider.RuntimeEventTurnPlanUpdated, Provider: "test", ThreadID: string(threadID), TurnID: "turn-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{PlanEntries: []provider.PlanEntry{
		{Content: "investigate", Priority: "high", Status: "in_progress"},
		{Content: "fix", Priority: "medium", Status: "pending"},
	}}})

	thread, ok := engine.Thread(threadID)
	if !ok || thread.Plan == nil {
		t.Fatalf("thread.Plan missing")
	}
	if len(thread.Plan.Entries) != 2 || thread.Plan.Entries[0].Content != "investigate" || thread.Plan.Entries[0].Status != provider.PlanEntryStatusInProgress {
		t.Fatalf("plan = %#v, want two checklist entries", thread.Plan)
	}

	// A second update fully replaces the plan.
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-plan-2", Type: provider.RuntimeEventTurnPlanUpdated, Provider: "test", ThreadID: string(threadID), TurnID: "turn-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{PlanEntries: []provider.PlanEntry{{Content: "done", Priority: "low", Status: "completed"}}}})
	thread, _ = engine.Thread(threadID)
	if len(thread.Plan.Entries) != 1 || thread.Plan.Entries[0].Status != provider.PlanEntryStatusCompleted {
		t.Fatalf("plan after replace = %#v, want single completed entry", thread.Plan)
	}
}

func TestIngestionSessionScopedUpdatesBeforeBindingSurviveSessionStatusSet(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-prebinding-updates")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "create-prebinding-updates", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"})

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-prebinding-config", Type: provider.RuntimeEventConfigOptionsUpdated, Provider: "test", ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ConfigOptions: []provider.ConfigOption{{ID: "model", Category: provider.ConfigOptionCategoryModel, CurrentValue: "fast"}}}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-prebinding-slash", Type: provider.RuntimeEventThreadMetadataUpdate, Provider: "test", ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{SlashCommands: []provider.SlashCommand{{Name: "compact"}}}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-prebinding-usage", Type: provider.RuntimeEventThreadTokenUsage, Provider: "test", ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TokenUsage: &provider.TokenUsage{UsedTokens: 42, MaxTokens: 100}}})

	// The reactor binds sessions through bound UPDATES; the engine merges the
	// provider identity over the live session, so metadata that arrived
	// before the binding survives.
	if _, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateBound, Binding: &SessionBinding{ProviderInstanceID: "codex"}}); err != nil {
		t.Fatalf("thread.session.status.set bound update: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	if thread.Session == nil || thread.Session.Status != SessionStatusReady {
		t.Fatalf("session after bound update = %#v, want ready binding", thread.Session)
	}
	if len(thread.Session.ConfigOptions) != 1 || thread.Session.ConfigOptions[0].CurrentValue != "fast" {
		t.Fatalf("config options after session status set = %#v, want preserved model option", thread.Session.ConfigOptions)
	}
	if len(thread.Session.SlashCommands) != 1 || thread.Session.SlashCommands[0].Name != "compact" {
		t.Fatalf("slash commands after session status set = %#v, want compact preserved", thread.Session.SlashCommands)
	}
	if thread.Session.TokenUsage == nil || thread.Session.TokenUsage.UsedTokens != 42 {
		t.Fatalf("token usage after session status set = %#v, want preserved usage", thread.Session.TokenUsage)
	}
}

func TestIngestionEmptyListUpdatesMarshalExplicitArrays(t *testing.T) {
	engine := NewEngine()
	events := observeEvents(t, engine)
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-empty-list-json")
	newThreadWithSession(t, engine, threadID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-full-config", Type: provider.RuntimeEventConfigOptionsUpdated, ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ConfigOptions: []provider.ConfigOption{{ID: "model", Category: provider.ConfigOptionCategoryModel, CurrentValue: "fast"}}}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-full-slash", Type: provider.RuntimeEventThreadMetadataUpdate, ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{SlashCommands: []provider.SlashCommand{{Name: "compact"}}}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-empty-config", Type: provider.RuntimeEventConfigOptionsUpdated, ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ConfigOptions: []provider.ConfigOption{}}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-empty-slash", Type: provider.RuntimeEventThreadMetadataUpdate, ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{SlashCommands: []provider.SlashCommand{}}})

	var configJSON, slashJSON json.RawMessage
	for _, event := range events.matching("", 0) {
		raw, err := json.Marshal(event.Payload)
		if err != nil {
			t.Fatalf("marshal payload: %v", err)
		}
		var payload map[string]json.RawMessage
		if err := json.Unmarshal(raw, &payload); err != nil {
			t.Fatalf("unmarshal payload: %v", err)
		}
		switch event.Type {
		case EventThreadConfigOptionsUpdated:
			configJSON = append(configJSON[:0], payload["configOptions"]...)
		case EventThreadSlashCommandsUpdated:
			slashJSON = append(slashJSON[:0], payload["slashCommands"]...)
		}
	}
	if string(configJSON) != "[]" || string(slashJSON) != "[]" {
		t.Fatalf("last list payloads = config:%s slash:%s, want explicit empty arrays", configJSON, slashJSON)
	}

	thread, ok := engine.Thread(threadID)
	if !ok || thread.Session == nil {
		t.Fatalf("thread session = %#v, want session", thread.Session)
	}
	raw, err := json.Marshal(thread.Session)
	if err != nil {
		t.Fatalf("marshal session: %v", err)
	}
	var session map[string]json.RawMessage
	if err := json.Unmarshal(raw, &session); err != nil {
		t.Fatalf("unmarshal session: %v", err)
	}
	if string(session["configOptions"]) != "[]" {
		t.Fatalf("session JSON = %s, want configOptions:[] after clear", raw)
	}
	if string(session["slashCommands"]) != "[]" {
		t.Fatalf("session JSON = %s, want slashCommands:[] after clear", raw)
	}
}

func TestIngestionProjectsAssistantAttachments(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-assistant-attachment")
	newThreadWithSession(t, engine, threadID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-image", Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), ItemID: "provider-assistant-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Attachments: []provider.Attachment{{Kind: "image", MimeType: "image/png", Data: "base64"}}}})
	thread, ok := engine.Thread(threadID)
	if !ok || len(thread.Timeline.Messages()) != 1 || len(thread.Timeline.Messages()[0].Attachments) != 1 || thread.Timeline.Messages()[0].Attachments[0].Kind != "image" {
		t.Fatalf("messages = %#v, want assistant image attachment preserved", thread.Timeline.Messages())
	}
}

func TestIngestionCompletesReplayedAssistantMessageItem(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-replayed-assistant-message")
	newThreadWithSession(t, engine, threadID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-assistant-replay-delta", Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), ItemID: "provider-assistant-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "hello"}})
	thread, ok := engine.Thread(threadID)
	if !ok || len(thread.Timeline.Messages()) != 0 {
		t.Fatalf("messages after replay delta = %#v, want the first chunk buffered", thread.Timeline.Messages())
	}

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-assistant-replay-complete", Type: provider.RuntimeEventItemCompleted, Provider: "test", ThreadID: string(threadID), ItemID: "provider-assistant-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindAssistantMessage, ItemStatus: provider.ItemStatusCompleted}})
	thread, _ = engine.Thread(threadID)
	if len(thread.Timeline.Messages()) != 1 || thread.Timeline.Messages()[0].ID != "assistant:provider-assistant-1" || thread.Timeline.Messages()[0].Text != "hello" {
		t.Fatalf("messages after replay completion = %#v, want completed assistant message", thread.Timeline.Messages())
	}
}

func TestIngestionSeparatesAssistantMessagesByProviderMessageID(t *testing.T) {
	engine := NewEngine()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-assistant-message-ids")
	newThreadWithSession(t, engine, threadID)
	mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "turn-assistant-message-ids", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-user", Text: "hello"}, CreatedAt: time.Now()})
	thread, _ := engine.Thread(threadID)
	turnID := string(thread.LatestTurn.ID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-msg-1", Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: turnID, ItemID: "provider-msg-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "first"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-msg-2", Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: turnID, ItemID: "provider-msg-2", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "second"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-complete", Type: provider.RuntimeEventTurnCompleted, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCompleted, StopReason: "end_turn"}})

	thread, _ = engine.Thread(threadID)
	if len(thread.Timeline.Messages()) != 3 {
		t.Fatalf("messages = %#v, want user plus two assistant messages", thread.Timeline.Messages())
	}
	if thread.Timeline.Messages()[1].ID != "assistant:provider-msg-1" || thread.Timeline.Messages()[1].Text != "first" {
		t.Fatalf("first assistant = %#v", thread.Timeline.Messages()[1])
	}
	if thread.Timeline.Messages()[2].ID != "assistant:provider-msg-2" || thread.Timeline.Messages()[2].Text != "second" {
		t.Fatalf("second assistant = %#v", thread.Timeline.Messages()[2])
	}
	if thread.LatestTurn == nil || thread.LatestTurn.StopReason != "end_turn" {
		t.Fatalf("latest turn = %#v, want runtime stop reason forwarded through ingestion", thread.LatestTurn)
	}
}

// Regression: a session stop landing before a turn's completion settles must
// not be resurrected Stopped->Ready by that completion. The old ingestion path
// computed its guards from one SessionView and built the status binding from
// a SECOND read, so a stop landing between the reads revived the session; the
// engine now derives the binding and applies the stopped-preservation guard
// atomically under its write lock (the settle update is dropped: no event).
func TestIngestionTurnCompletionAfterStopPreservesStoppedSession(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	events := observeEvents(t, engine)
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-stop-vs-completion")
	newThreadWithSession(t, engine, threadID)
	mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "turn-stop-vs-completion", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-stop-vs-completion", Text: "hello"}, CreatedAt: time.Now()})
	thread, _ := engine.Thread(threadID)
	turnID := string(thread.LatestTurn.ID)
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-started-before-stop", Type: provider.RuntimeEventTurnStarted, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now()})

	// The stop confirmation wins the race with the turn completion.
	stopResult, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateStopped})
	if err != nil || stopResult.Sequence == 0 {
		t.Fatalf("stopped update = (%#v, %v), want accepted append", stopResult, err)
	}
	stoppedSequence := stopResult.Sequence

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-late-completed", Type: provider.RuntimeEventTurnCompleted, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCompleted}})

	thread, _ = engine.Thread(threadID)
	if thread.Session == nil || thread.Session.Status != SessionStatusStopped || thread.Session.ActiveTurnID != "" {
		t.Fatalf("session = %#v, want stopped session preserved after late completion", thread.Session)
	}
	if thread.LatestTurn == nil || thread.LatestTurn.ID != TurnID(turnID) || thread.LatestTurn.State != TurnStateInterrupted || thread.LatestTurn.CompletedAt == nil {
		t.Fatalf("latest turn = %#v, want stopped turn to remain interrupted/completed", thread.LatestTurn)
	}
	for _, event := range events.matching(threadID, stoppedSequence) {
		if event.Type == EventThreadSessionStatusSet {
			t.Fatalf("session status appended after stop: %#v, want late completion dropped", event.Payload.Session)
		}
	}
}

// Terminal events for a superseded turn arrive late. A stale settle must still
// flush that turn's buffered text and free its buffers (otherwise the text is
// lost and the turns map leaks), and neither a stale settle nor a stale runtime
// error may touch the current turn, whether it is running or already settled.
func TestIngestionStaleTerminalEventsForOldTurn(t *testing.T) {
	pinFlushInterval(t, time.Hour)
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-stale-old-turn")
	newThreadWithSession(t, engine, threadID)
	ingest := func(eventType provider.RuntimeEventType, turnID TurnID, payload provider.RuntimeEventPayload) {
		ingestion.Ingest(provider.RuntimeEvent{Type: eventType, Provider: "test", ThreadID: string(threadID), TurnID: string(turnID), CreatedAt: time.Now(), Payload: payload})
	}
	startTurn := func(text string) TurnID {
		mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: CommandID("turn-" + text), ThreadID: threadID, Message: &CommandMessage{Text: text}})
		thread, _ := engine.Thread(threadID)
		return thread.LatestTurn.ID
	}
	assertCurrent := func(step string, status SessionStatus, turnID TurnID, state TurnState) Thread {
		t.Helper()
		thread, _ := engine.Thread(threadID)
		wantActive := TurnID("")
		if status == SessionStatusRunning {
			wantActive = turnID
		}
		if thread.Session.Status != status || thread.Session.ActiveTurnID != wantActive || thread.LatestTurn.ID != turnID || thread.LatestTurn.State != state || thread.LatestTurn.Error != "" {
			t.Fatalf("%s: session %#v, latest turn %#v, want %s on %s (%s)", step, thread.Session, thread.LatestTurn, status, turnID, state)
		}
		return thread
	}

	oldTurn := startTurn("old")
	ingest(provider.RuntimeEventContentDelta, oldTurn, provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "partial"})
	// The old turn settles session-side without its terminal event reaching
	// ingestion (e.g. it was lost), and a new turn starts.
	if result, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateTurnSettled, TurnID: oldTurn, TurnState: provider.RuntimeTurnInterrupted}); err != nil || result.Sequence == 0 {
		t.Fatalf("old turn settle update = (%#v, %v), want accepted", result, err)
	}
	newTurn := startTurn("new")

	ingest(provider.RuntimeEventTurnCompleted, oldTurn, provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCancelled})
	thread := assertCurrent("stale settle", SessionStatusRunning, newTurn, TurnStateRunning)
	if messages := thread.Timeline.Messages(); !slices.ContainsFunc(messages, func(message Message) bool {
		return message.Role == MessageRoleAssistant && message.TurnID == oldTurn && message.Text == "partial"
	}) {
		t.Fatalf("messages = %#v, want the old turn's buffered text flushed despite the stale settle", messages)
	}
	ingestion.mu.Lock()
	_, leaked := ingestion.turns[turnKey{threadID: string(threadID), turnID: string(oldTurn)}]
	ingestion.mu.Unlock()
	if leaked {
		t.Fatal("ingestion turns map still holds the stale-settled turn")
	}

	ingest(provider.RuntimeEventRuntimeError, oldTurn, provider.RuntimeEventPayload{Message: "late boom"})
	thread = assertCurrent("stale runtime error", SessionStatusRunning, newTurn, TurnStateRunning)
	if items := thread.Timeline.Items(); len(items) != 1 || items[0].Kind != provider.ItemKindError || items[0].TurnID != oldTurn || items[0].Title != "late boom" {
		t.Fatalf("items = %#v, want the stale error kept as an item scoped to the old turn", items)
	}

	ingest(provider.RuntimeEventTurnCompleted, newTurn, provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCompleted})
	ingest(provider.RuntimeEventTurnCompleted, oldTurn, provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCancelled})
	assertCurrent("stale settle after the current turn completed", SessionStatusReady, newTurn, TurnStateCompleted)
}

// When a NEWER turn settles, buffered streams of the thread's OLDER turns are
// settled too (their own terminal event will never arrive), so no buffered
// text is lost and the turns map cannot leak.
func TestIngestionSettlesOlderTurnBuffersWhenNewerTurnSettles(t *testing.T) {
	pinFlushInterval(t, time.Hour)
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-older-turn-buffers")
	newThreadWithSession(t, engine, threadID)
	mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "turn-older-buffers-old", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-older-buffers-old", Text: "old"}, CreatedAt: time.Now()})
	thread, _ := engine.Thread(threadID)
	oldTurnID := string(thread.LatestTurn.ID)
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-older-delta", Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: oldTurnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "orphaned"}})

	if result, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateTurnSettled, TurnID: TurnID(oldTurnID), TurnState: provider.RuntimeTurnInterrupted}); err != nil || result.Sequence == 0 {
		t.Fatalf("old turn settle update = (%#v, %v), want accepted", result, err)
	}
	mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "turn-older-buffers-new", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-older-buffers-new", Text: "new"}, CreatedAt: time.Now()})
	thread, _ = engine.Thread(threadID)
	newTurnID := string(thread.LatestTurn.ID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-newer-complete", Type: provider.RuntimeEventTurnCompleted, Provider: "test", ThreadID: string(threadID), TurnID: newTurnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCompleted}})

	thread, _ = engine.Thread(threadID)
	if thread.Session == nil || thread.Session.Status != SessionStatusReady {
		t.Fatalf("session = %#v, want ready after newer turn settled", thread.Session)
	}
	var orphaned *Message
	for idx := range thread.Timeline.Messages() {
		if thread.Timeline.Messages()[idx].Role == MessageRoleAssistant && thread.Timeline.Messages()[idx].TurnID == TurnID(oldTurnID) {
			orphaned = &thread.Timeline.Messages()[idx]
		}
	}
	if orphaned == nil || orphaned.Text != "orphaned" {
		t.Fatalf("old turn assistant message = %#v, want buffered text flushed when the newer turn settled", orphaned)
	}
	ingestion.mu.Lock()
	remaining := len(ingestion.turns)
	ingestion.mu.Unlock()
	if remaining != 0 {
		t.Fatalf("ingestion turns map holds %d entries after newer turn settled, want 0", remaining)
	}
}

func TestIngestionItemUpsertTracksToolCallLifecycle(t *testing.T) {
	engine := NewEngine()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-item")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "create-item", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"})

	// Providers send the COMPLETE neutral tool-call state on every data-bearing
	// event (the ACP adapter accumulates sparse updates itself); a status-only
	// update keeps the previous snapshot.
	startTool := &provider.ToolCall{Action: provider.ToolActionExecute, Command: "go test ./...", Locations: []provider.ToolLocation{{Path: "main.go"}}}
	doneValue := *startTool
	doneTool := &doneValue
	doneTool.Output = "ok"
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-item-start", Type: provider.RuntimeEventItemStarted, Provider: "test", ThreadID: string(threadID), TurnID: "turn-1", ItemID: "tool-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution, Title: "run tests", ToolCall: startTool}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-item-done", Type: provider.RuntimeEventItemCompleted, Provider: "test", ThreadID: string(threadID), TurnID: "turn-1", ItemID: "tool-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution, ToolCall: doneTool}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-item-status-only", Type: provider.RuntimeEventItemUpdated, Provider: "test", ThreadID: string(threadID), TurnID: "turn-1", ItemID: "tool-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution}})

	thread, ok := engine.Thread(threadID)
	if !ok {
		t.Fatalf("thread missing")
	}
	if len(thread.Timeline.Items()) != 1 {
		t.Fatalf("items = %#v, want a single upserted tool item", thread.Timeline.Items())
	}
	item := thread.Timeline.Items()[0]
	if item.ID != "tool-1" || item.Kind != provider.ItemKindCommandExecution || item.Status != provider.ItemStatusCompleted || item.Title != "run tests" {
		t.Fatalf("item = %#v, want completed command_execution keeping its title", item)
	}
	if item.ToolCall == nil || item.ToolCall.Command != "go test ./..." || len(item.ToolCall.Locations) != 1 || item.ToolCall.Locations[0].Path != "main.go" || item.ToolCall.Output != "ok" {
		t.Fatalf("item tool call = %#v, want the completed neutral snapshot", item.ToolCall)
	}

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-item-interrupted", Type: provider.RuntimeEventItemUpdated, Provider: "test", ThreadID: string(threadID), TurnID: "turn-1", ItemID: "tool-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution, ItemStatus: provider.ItemStatusInterrupted}})
	thread, _ = engine.Thread(threadID)
	item = thread.Timeline.Items()[0]
	if item.Status != provider.ItemStatusInterrupted || item.Kind != provider.ItemKindCommandExecution || item.Title != "run tests" || item.ToolCall == nil {
		t.Fatalf("interrupted item = %#v, want interrupted status preserving kind, title, and tool call", item)
	}
}

// TestIngestionReasoningPreservesNonTextContent: ACP thought chunks are full
// ContentBlocks, so a reasoning chunk can carry an image/audio/resource
// attachment. Text streams as coalesced textDelta events; a chunk WITH an
// attachment flushes immediately as the complete replacement payload (an
// attachment must not stay hidden until settle), and the settle checkpoint
// retains everything.
func TestIngestionReasoningPreservesNonTextContent(t *testing.T) {
	pinFlushInterval(t, time.Hour)
	engine := NewEngine()
	events := observeEvents(t, engine)
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-reasoning-content")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "create-reasoning-content", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"})
	turnID := "turn-reasoning-content"
	image := provider.Attachment{Kind: "image", MimeType: "image/png", Data: "iVBORw0K"}

	reasoningChunk := func(eventID string, delta string, attachments []provider.Attachment) provider.RuntimeEvent {
		return provider.RuntimeEvent{EventID: provider.RuntimeEventID(eventID), Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: delta, Attachments: attachments}}
	}
	ingestion.Ingest(reasoningChunk("evt-r1", "look at ", nil))
	ingestion.Ingest(reasoningChunk("evt-r2", "this:", []provider.Attachment{image}))

	// The attachment chunk must be visible immediately, not at settle.
	midThread, _ := engine.Thread(threadID)
	var mid reasoningPayload
	for _, item := range midThread.Timeline.Items() {
		if item.Kind == provider.ItemKindReasoning {
			if err := json.Unmarshal(item.Payload, &mid); err != nil {
				t.Fatalf("unmarshal mid-stream reasoning payload: %v (%s)", err, item.Payload)
			}
		}
	}
	if mid.Text != "look at this:" || len(mid.Attachments) != 1 {
		t.Fatalf("mid-stream reasoning payload = %#v, want attachment chunk flushed as complete payload", mid)
	}

	ingestion.Ingest(reasoningChunk("evt-r3", " interesting", nil))
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-r-done", Type: provider.RuntimeEventTurnCompleted, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCompleted}})

	thread, _ := engine.Thread(threadID)
	var payload reasoningPayload
	found := false
	for _, item := range thread.Timeline.Items() {
		if item.Kind == provider.ItemKindReasoning {
			found = true
			if err := json.Unmarshal(item.Payload, &payload); err != nil {
				t.Fatalf("unmarshal reasoning payload: %v (%s)", err, item.Payload)
			}
		}
	}
	if !found {
		t.Fatalf("no reasoning item in %#v", thread.Timeline.Items())
	}
	if payload.Text != "look at this: interesting" {
		t.Fatalf("reasoning text = %q, want full accumulated text across delta and full-payload chunks", payload.Text)
	}
	if len(payload.Attachments) != 1 || payload.Attachments[0].Kind != "image" || payload.Attachments[0].Data != "iVBORw0K" {
		t.Fatalf("reasoning attachments = %#v, want the image preserved through deltas and the settle checkpoint", payload.Attachments)
	}

	// Event-level contract: with the interval pinned, exactly two reasoning
	// events — the attachment chunk's full replacement payload and the settle
	// checkpoint. The earlier text chunk is folded into the attachment payload.
	reasoningEvents := 0
	for _, event := range events.matching(threadID, 0) {
		if event.Type != EventThreadItemUpserted || event.Payload.Item == nil || event.Payload.Item.Kind != provider.ItemKindReasoning {
			continue
		}
		if event.Payload.Item.TextDelta != "" && len(event.Payload.Item.Payload) != 0 {
			t.Fatalf("reasoning event carries both textDelta and payload: %#v", event.Payload.Item)
		}
		reasoningEvents++
	}
	if reasoningEvents != 2 {
		t.Fatalf("reasoning events = %d, want attachment payload and settle checkpoint only", reasoningEvents)
	}
}

// A completed reasoning item that carries the provider's full text settles
// with that text, not with the streamed accumulation, so the settled item
// matches what the provider will replay.
func TestIngestionCompletedReasoningSnapshotIsAuthoritative(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-reasoning-snapshot")
	newThreadWithSession(t, engine, threadID)
	mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "turn-reasoning-snapshot", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-user", Text: "hello"}, CreatedAt: time.Now()})
	thread, _ := engine.Thread(threadID)
	turnID := string(thread.LatestTurn.ID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-snapshot-delta", Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: turnID, ItemID: "reason-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: "firstsecond"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-snapshot-completed", Type: provider.RuntimeEventItemCompleted, Provider: "test", ThreadID: string(threadID), TurnID: turnID, ItemID: "reason-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindReasoning, ItemStatus: provider.ItemStatusCompleted, Detail: "first\n\nsecond"}})

	thread, _ = engine.Thread(threadID)
	if got, want := describeTimeline(thread.Timeline), []string{"user:hello", "reasoning(completed):first\n\nsecond"}; !slices.Equal(got, want) {
		t.Fatalf("timeline = %q, want %q", got, want)
	}
}

// A stopped turn keeps its own outcome and timing after a late tool completion
// and the next turn replace it as the latest turn.
func TestPreviousTurnKeepsStoppedOutcomeAfterNextTurnStarts(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-previous-turn-outcome")
	newThreadWithSession(t, engine, threadID)
	start := time.Now()
	mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "turn-stopped", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-stopped", Text: "long command"}, CreatedAt: start})
	thread, _ := engine.Thread(threadID)
	stoppedTurn := string(thread.LatestTurn.ID)
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-stopped-started", Type: provider.RuntimeEventTurnStarted, Provider: "test", ThreadID: string(threadID), TurnID: stoppedTurn, CreatedAt: start})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-stopped", Type: provider.RuntimeEventTurnCompleted, Provider: "test", ThreadID: string(threadID), TurnID: stoppedTurn, CreatedAt: start.Add(9 * time.Second), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnInterrupted}})
	thread, _ = engine.Thread(threadID)
	stopped := *thread.LatestTurn
	if stopped.State != TurnStateInterrupted || stopped.CompletedAt == nil {
		t.Fatalf("stopped turn = %#v, want interrupted", stopped)
	}
	// The provider's command still finishes after the stop.
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-late-tool", Type: provider.RuntimeEventItemCompleted, Provider: "test", ThreadID: string(threadID), TurnID: stoppedTurn, ItemID: "late-tool", CreatedAt: start.Add(49 * time.Second), Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution, ItemStatus: provider.ItemStatusCompleted}})

	mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "turn-next", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-next", Text: "next"}, CreatedAt: start.Add(60 * time.Second)})
	snapshot, err := engine.SubscribeThread(SubscribeThreadInput{ThreadID: threadID})
	if err != nil {
		t.Fatalf("SubscribeThread: %v", err)
	}
	client := snapshot.Snapshot.Thread
	if client.LatestTurn == nil || client.LatestTurn.ID == TurnID(stoppedTurn) {
		t.Fatalf("latest turn = %#v, want the next turn", client.LatestTurn)
	}
	if len(client.PreviousTurns) != 1 {
		t.Fatalf("previous turns = %#v, want the stopped turn", client.PreviousTurns)
	}
	previous := client.PreviousTurns[0]
	if previous.ID != TurnID(stoppedTurn) || previous.State != TurnStateInterrupted || previous.CompletedAt == nil || !previous.CompletedAt.Equal(*stopped.CompletedAt) || !previous.RequestedAt.Equal(stopped.RequestedAt) {
		t.Fatalf("previous turn = %#v, want stopped outcome and timing %#v", previous, stopped)
	}
}

// After a daemon restart the thread is rebuilt from provider history. Each
// settled turn keeps the outcome and timing its history reports, including an
// interrupted turn whose late tool completed after the stop.
func TestRestoredHistoryKeepsEachTurnOutcomeAndTiming(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-restored-turn-outcomes")
	now := time.Now().UTC()
	engine.RestoreThreads([]RestoredThread{{ThreadID: threadID, ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now}})
	// Like reopening the thread: the session is starting while history replays.
	mustAppend(t, engine, EventInput{Type: EventThreadSessionPrepareRequested, ThreadID: threadID, Actor: ActorKindClient, OccurredAt: now})
	stoppedAt := now.Add(-time.Hour)
	nextAt := stoppedAt.Add(time.Minute)
	boundary := func(eventType provider.RuntimeEventType, turnID string, at time.Time, state provider.RuntimeTurnState) provider.RuntimeEvent {
		return provider.RuntimeEvent{EventID: provider.RuntimeEventID(turnID + string(eventType)), Type: eventType, ThreadID: string(threadID), TurnID: turnID, CreatedAt: at, Payload: provider.RuntimeEventPayload{TurnState: state}}
	}
	replay := []provider.RuntimeEvent{
		boundary(provider.RuntimeEventTurnStarted, "turn-stopped", stoppedAt, ""),
		{EventID: "late-tool", Type: provider.RuntimeEventItemCompleted, ThreadID: string(threadID), TurnID: "turn-stopped", ItemID: "late-tool", CreatedAt: stoppedAt.Add(time.Microsecond), Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution, ItemStatus: provider.ItemStatusCompleted}},
		boundary(provider.RuntimeEventTurnCompleted, "turn-stopped", stoppedAt.Add(9*time.Second), provider.RuntimeTurnInterrupted),
		boundary(provider.RuntimeEventTurnStarted, "turn-next", nextAt, ""),
		boundary(provider.RuntimeEventTurnCompleted, "turn-next", nextAt.Add(4*time.Second), provider.RuntimeTurnCompleted),
	}
	if err := ingestion.RestoreHistory(string(threadID), func() (provider.StartSessionResult, error) {
		return provider.StartSessionResult{Session: provider.Session{ThreadID: string(threadID), ProviderInstanceID: "codex"}, Replay: replay}, nil
	}, func(provider.Session) {}); err != nil {
		t.Fatalf("RestoreHistory: %v", err)
	}

	snapshot, err := engine.SubscribeThread(SubscribeThreadInput{ThreadID: threadID})
	if err != nil {
		t.Fatalf("SubscribeThread: %v", err)
	}
	thread := snapshot.Snapshot.Thread
	if thread.LatestTurn == nil || thread.LatestTurn.ID != "turn-next" {
		t.Fatalf("latest turn = %#v, want the last replayed turn", thread.LatestTurn)
	}
	turns := append(append([]Turn(nil), thread.PreviousTurns...), *thread.LatestTurn)
	if len(turns) != 2 {
		t.Fatalf("previous turns = %#v, want only the stopped turn", thread.PreviousTurns)
	}
	want := []struct {
		id       TurnID
		state    TurnState
		duration time.Duration
	}{{"turn-stopped", TurnStateInterrupted, 9 * time.Second}, {"turn-next", TurnStateCompleted, 4 * time.Second}}
	for index, expected := range want {
		turn := turns[index]
		if turn.ID != expected.id || turn.State != expected.state || turn.StartedAt == nil || turn.CompletedAt == nil || turn.CompletedAt.Sub(*turn.StartedAt) != expected.duration {
			t.Fatalf("previous turn %d = %#v, want %s %s over %s", index, turn, expected.id, expected.state, expected.duration)
		}
	}
}

// describeTimeline renders a timeline as "role:text", "kind(status):text" and
// "approval:requestId" entries so order and segmentation compare as one value.
func describeTimeline(timeline Timeline) []string {
	var described []string
	for _, entry := range timeline {
		switch {
		case entry.Message != nil:
			described = append(described, string(entry.Message.Role)+":"+entry.Message.Text)
		case entry.Item != nil:
			text := entry.Item.Title
			if entry.Item.Kind == provider.ItemKindReasoning {
				var payload reasoningPayload
				_ = json.Unmarshal(entry.Item.Payload, &payload)
				text = payload.Text
			}
			described = append(described, fmt.Sprintf("%s(%s):%s", entry.Item.Kind, entry.Item.Status, text))
		case entry.Approval != nil:
			described = append(described, "approval:"+entry.Approval.RequestID)
		}
	}
	return described
}

func TestIngestionProjectsProviderFailuresAndWarnings(t *testing.T) {
	tests := []struct {
		name          string
		activeTurn    bool
		event         provider.RuntimeEvent
		wantSession   SessionStatus
		wantLastError string
		wantTurn      TurnState
		wantItem      string
	}{
		{
			name:          "runtime error without a turn",
			event:         provider.RuntimeEvent{Type: provider.RuntimeEventRuntimeError, Payload: provider.RuntimeEventPayload{Message: "boom"}},
			wantSession:   SessionStatusError,
			wantLastError: "boom",
			wantItem:      "error(failed):boom",
		},
		{
			name:          "runtime error on the active turn",
			activeTurn:    true,
			event:         provider.RuntimeEvent{Type: provider.RuntimeEventRuntimeError, Payload: provider.RuntimeEventPayload{Message: "provider failed"}},
			wantSession:   SessionStatusError,
			wantLastError: "provider failed",
			wantTurn:      TurnStateError,
			wantItem:      "error(failed):provider failed",
		},
		{
			name:          "failed turn completion",
			activeTurn:    true,
			event:         provider.RuntimeEvent{Type: provider.RuntimeEventTurnCompleted, Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnFailed, Message: "provider exploded"}},
			wantSession:   SessionStatusError,
			wantLastError: "provider exploded",
			wantTurn:      TurnStateError,
			wantItem:      "error(failed):provider exploded",
		},
		{
			name:        "warning leaves the session usable",
			event:       provider.RuntimeEvent{Type: provider.RuntimeEventRuntimeWarning, TurnID: "turn-warning", Payload: provider.RuntimeEventPayload{Message: "plan mode was not applied"}},
			wantSession: SessionStatusReady,
			wantItem:    "warning(completed):plan mode was not applied",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			engine := NewEngine()
			defer engine.Close()
			ingestion := NewProviderRuntimeIngestion(engine)
			threadID := ThreadID("thread-failure")
			newThreadWithSession(t, engine, threadID)
			event := tt.event
			if tt.activeTurn {
				mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "turn-failure", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-user", Text: "hello"}})
				thread, _ := engine.Thread(threadID)
				event.TurnID = string(thread.LatestTurn.ID)
			}
			event.EventID = "evt-failure"
			event.ThreadID = string(threadID)
			event.CreatedAt = time.Now()
			ingestion.Ingest(event)

			thread, _ := engine.Thread(threadID)
			if thread.Session == nil || thread.Session.Status != tt.wantSession || thread.Session.LastError != tt.wantLastError || thread.Session.ActiveTurnID != "" {
				t.Fatalf("session = %#v, want %s with lastError %q and no active turn", thread.Session, tt.wantSession, tt.wantLastError)
			}
			if tt.wantTurn != "" && (thread.LatestTurn == nil || thread.LatestTurn.State != tt.wantTurn) {
				t.Fatalf("latest turn = %#v, want %s", thread.LatestTurn, tt.wantTurn)
			}
			items := thread.Timeline.Items()
			if len(items) != 1 || describeTimeline(Timeline{{Kind: TimelineEntryItem, Item: &items[0]}})[0] != tt.wantItem || items[0].TurnID != TurnID(event.TurnID) || items[0].ID != "evt-failure" {
				t.Fatalf("items = %#v, want %q scoped to turn %q", items, tt.wantItem, event.TurnID)
			}
		})
	}
}

func TestIngestionReplayOrdersAndCoalescesMessages(t *testing.T) {
	user := func(turnID, itemID, text string) provider.RuntimeEvent {
		return provider.RuntimeEvent{Type: provider.RuntimeEventItemCompleted, TurnID: turnID, ItemID: itemID, Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, Detail: text}}
	}
	delta := func(kind provider.RuntimeContentStreamKind, turnID, itemID, text string) provider.RuntimeEvent {
		return provider.RuntimeEvent{Type: provider.RuntimeEventContentDelta, TurnID: turnID, ItemID: itemID, Payload: provider.RuntimeEventPayload{StreamKind: kind, Delta: text}}
	}
	runtime := func(eventType provider.RuntimeEventType, message string) provider.RuntimeEvent {
		return provider.RuntimeEvent{Type: eventType, Payload: provider.RuntimeEventPayload{Message: message}}
	}
	assistant := provider.RuntimeContentAssistantText
	reasoning := provider.RuntimeContentReasoningText
	tests := []struct {
		name   string
		events []provider.RuntimeEvent
		want   []string
	}{
		{
			name:   "item ids without turn ids",
			events: []provider.RuntimeEvent{user("", "user-1", "first question"), delta(assistant, "", "assistant-1", "first answer"), user("", "user-2", "second question"), delta(assistant, "", "assistant-2", "second answer")},
			want:   []string{"user:first question", "assistant:first answer", "user:second question", "assistant:second answer"},
		},
		{
			name: "turn ids settle trailing reasoning",
			events: []provider.RuntimeEvent{
				user("turn-1", "user-1", "first question"), delta(assistant, "turn-1", "assistant-1", "first answer"),
				user("turn-2", "user-2", "second question"), delta(assistant, "turn-2", "assistant-2", "second answer"),
				delta(reasoning, "turn-2", "", "second thought"),
			},
			want: []string{"user:first question", "assistant:first answer", "user:second question", "assistant:second answer", "reasoning(completed):second thought"},
		},
		{
			name: "id-less chunks coalesce per message",
			events: []provider.RuntimeEvent{
				user("", "", "first "), user("", "", "question"), delta(assistant, "", "", "first "), delta(assistant, "", "", "answer"),
				user("", "", "second "), user("", "", "question"), delta(assistant, "", "", "second "), delta(assistant, "", "", "answer"),
			},
			want: []string{"user:first question", "assistant:first answer", "user:second question", "assistant:second answer"},
		},
		{
			// A warning flushes every buffered stream; a turn-less error settles
			// the streams (failing reasoning) before its item.
			name: "warning and error follow buffered text",
			events: []provider.RuntimeEvent{
				delta(assistant, "", "", "answer"), runtime(provider.RuntimeEventRuntimeWarning, "warned"),
				delta(reasoning, "", "", "thought"), runtime(provider.RuntimeEventRuntimeError, "failed"),
			},
			want: []string{"assistant:answer", "warning(completed):warned", "reasoning(failed):thought", "error(failed):failed"},
		},
		{
			name: "reasoning before warning and assistant before error",
			events: []provider.RuntimeEvent{
				delta(reasoning, "", "", "thought"), runtime(provider.RuntimeEventRuntimeWarning, "warned"),
				delta(assistant, "", "", "answer"), runtime(provider.RuntimeEventRuntimeError, "failed"),
			},
			want: []string{"reasoning(completed):thought", "warning(completed):warned", "assistant:answer", "error(failed):failed"},
		},
		{
			name:   "user chunks with one item id merge",
			events: []provider.RuntimeEvent{user("", "provider-user-1", "hello "), user("", "provider-user-1", "again")},
			want:   []string{"user:hello again"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			engine := NewEngine()
			defer engine.Close()
			ingestion := NewProviderRuntimeIngestion(engine)
			threadID := ThreadID("thread-replay-order")
			now := time.Now()
			engine.RestoreThreads([]RestoredThread{{ThreadID: threadID, ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now}})
			for index, event := range tt.events {
				event.EventID = provider.RuntimeEventID(fmt.Sprintf("event-%d", index))
				event.ThreadID = string(threadID)
				ingestion.Ingest(event)
			}
			ingestion.completeHistoryReplay(string(threadID), nil)

			thread, _ := engine.Thread(threadID)
			if got := describeTimeline(thread.Timeline); !slices.Equal(got, tt.want) {
				t.Fatalf("timeline = %q, want %q", got, tt.want)
			}
			if thread.ReplayHistoryPending {
				t.Fatal("replay completion left restored history pending")
			}
			ingestion.mu.Lock()
			defer ingestion.mu.Unlock()
			if len(ingestion.turns) != 0 || len(ingestion.turnOrder) != 0 {
				t.Fatalf("replay completion left turn buffers: %#v / %#v", ingestion.turns, ingestion.turnOrder)
			}
		})
	}
}

// Turn settlement settles the turn's reasoning segment and, when the turn ends
// abnormally, its still-open provider items: adapters drop post-cancel updates,
// so an interrupted tool call would otherwise spin forever. A normally
// completed turn leaves provider items alone — the provider owns their outcome.
func TestIngestionTurnSettlementSettlesReasoningAndOpenItems(t *testing.T) {
	cases := []struct {
		turnState     provider.RuntimeTurnState
		wantReasoning provider.ItemStatus
		wantOpenItem  provider.ItemStatus
	}{
		{turnState: provider.RuntimeTurnCompleted, wantReasoning: provider.ItemStatusCompleted, wantOpenItem: provider.ItemStatusInProgress},
		{turnState: provider.RuntimeTurnFailed, wantReasoning: provider.ItemStatusFailed, wantOpenItem: provider.ItemStatusFailed},
		{turnState: provider.RuntimeTurnInterrupted, wantReasoning: provider.ItemStatusInterrupted, wantOpenItem: provider.ItemStatusInterrupted},
		{turnState: provider.RuntimeTurnCancelled, wantReasoning: provider.ItemStatusInterrupted, wantOpenItem: provider.ItemStatusInterrupted},
	}
	for _, tc := range cases {
		t.Run(string(tc.turnState), func(t *testing.T) {
			engine := NewEngine()
			defer engine.Close()
			ingestion := NewProviderRuntimeIngestion(engine)
			threadID := ThreadID("thread-settle-" + string(tc.turnState))
			newThreadWithSession(t, engine, threadID)
			mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "turn-settle", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-user", Text: "hello"}})
			thread, _ := engine.Thread(threadID)
			turnID := string(thread.LatestTurn.ID)
			ingest := func(event provider.RuntimeEvent) {
				event.Provider, event.ThreadID, event.TurnID, event.CreatedAt = "test", string(threadID), turnID, time.Now()
				ingestion.Ingest(event)
			}

			ingest(provider.RuntimeEvent{EventID: "tool-open", Type: provider.RuntimeEventItemStarted, ItemID: "tool-open", Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution, Title: "run tests"}})
			ingest(provider.RuntimeEvent{EventID: "tool-done-start", Type: provider.RuntimeEventItemStarted, ItemID: "tool-done", Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindFileChange, Title: "edit file"}})
			ingest(provider.RuntimeEvent{EventID: "tool-done-complete", Type: provider.RuntimeEventItemCompleted, ItemID: "tool-done", Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindFileChange}})
			ingest(provider.RuntimeEvent{EventID: "reasoning", Type: provider.RuntimeEventContentDelta, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: "thinking"}})
			ingestion.flushPendingText(time.Now())
			ingest(provider.RuntimeEvent{EventID: "turn-settle", Type: provider.RuntimeEventTurnCompleted, Payload: provider.RuntimeEventPayload{TurnState: tc.turnState, Message: "provider failed"}})

			thread, _ = engine.Thread(threadID)
			want := []string{
				"user:hello",
				fmt.Sprintf("command_execution(%s):run tests", tc.wantOpenItem),
				"file_change(completed):edit file",
				fmt.Sprintf("reasoning(%s):thinking", tc.wantReasoning),
			}
			got := describeTimeline(thread.Timeline)
			if len(got) < len(want) || !slices.Equal(got[:len(want)], want) {
				t.Fatalf("timeline = %q, want prefix %q", got, want)
			}
		})
	}
}

func TestIngestionBoundariesSplitBufferedTextInEncounterOrder(t *testing.T) {
	text := func(kind provider.RuntimeContentStreamKind, value string) provider.RuntimeEvent {
		return provider.RuntimeEvent{Type: provider.RuntimeEventContentDelta, Payload: provider.RuntimeEventPayload{StreamKind: kind, Delta: value}}
	}
	assistant := func(value string) provider.RuntimeEvent { return text(provider.RuntimeContentAssistantText, value) }
	reasoning := func(value string) provider.RuntimeEvent { return text(provider.RuntimeContentReasoningText, value) }
	toolStarted := provider.RuntimeEvent{Type: provider.RuntimeEventItemStarted, ItemID: "tool-1", Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution, Title: "run tests"}}
	toolUpdated := provider.RuntimeEvent{Type: provider.RuntimeEventItemUpdated, ItemID: "tool-1", Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution}}
	approvalOpened := provider.RuntimeEvent{Type: provider.RuntimeEventRequestOpened, RequestID: "approval-1", Payload: provider.RuntimeEventPayload{RequestType: provider.RuntimeRequestCommandExecution}}

	tests := []struct {
		name   string
		events []provider.RuntimeEvent
		want   []string
	}{
		{
			name:   "approval splits assistant text",
			events: []provider.RuntimeEvent{assistant("before approval"), approvalOpened, assistant("after approval")},
			want:   []string{"assistant:before approval", "approval:approval-1", "assistant:after approval"},
		},
		{
			name:   "tool splits assistant text",
			events: []provider.RuntimeEvent{assistant("before tool"), toolStarted, assistant("after tool")},
			want:   []string{"assistant:before tool", "command_execution(in_progress):run tests", "assistant:after tool"},
		},
		{
			name:   "tool splits reasoning and updates stay anchored",
			events: []provider.RuntimeEvent{reasoning("before tool"), toolStarted, toolUpdated, reasoning("after tool")},
			want:   []string{"reasoning(completed):before tool", "command_execution(in_progress):run tests", "reasoning(in_progress):after tool"},
		},
		{
			// Interleaved thinking: visible text before and between thinking.
			name:   "reasoning and assistant text interleave",
			events: []provider.RuntimeEvent{reasoning("think first"), assistant("answer once"), reasoning("think again"), assistant("answer twice")},
			want:   []string{"reasoning(completed):think first", "assistant:answer once", "reasoning(completed):think again", "assistant:answer twice"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			engine := NewEngine()
			defer engine.Close()
			ingestion := NewProviderRuntimeIngestion(engine)
			threadID := ThreadID("thread-boundaries")
			newThreadWithSession(t, engine, threadID)
			for index, event := range tt.events {
				event.EventID = provider.RuntimeEventID(fmt.Sprintf("event-%d", index))
				event.ThreadID, event.TurnID = string(threadID), "turn-1"
				ingestion.Ingest(event)
			}
			ingestion.flushPendingText(time.Now())

			thread, _ := engine.Thread(threadID)
			if got := describeTimeline(thread.Timeline); !slices.Equal(got, tt.want) {
				t.Fatalf("timeline = %q, want %q", got, tt.want)
			}
		})
	}
}
