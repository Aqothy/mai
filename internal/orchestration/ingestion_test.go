package orchestration

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
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
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: CommandID("create-" + string(threadID)), ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	binding := &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusReady, UpdatedAt: time.Now()}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: binding}}); err != nil {
		t.Fatalf("thread.session.status.set: %v", err)
	}
}

func TestRestoreHistoryDoesNotBlockOtherThreads(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
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

	events := engine.ReplayEvents(ReplayEventsInput{ThreadID: "restoring"})
	var messageSequence, queuedSequence, completionSequence, readySequence, afterReadySequence uint64
	for _, event := range events {
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

	ingestion.completeHistoryReplay(string(threadID))
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

func TestReplayWarningsAndErrorsFollowBufferedText(t *testing.T) {
	tests := []struct {
		name      string
		textEvent provider.RuntimeEvent
		lastType  provider.RuntimeEventType
		lastKind  provider.ItemKind
	}{
		{
			name:      "assistant then warning",
			textEvent: provider.RuntimeEvent{Type: provider.RuntimeEventContentDelta, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "answer"}},
			lastType:  provider.RuntimeEventRuntimeWarning,
			lastKind:  provider.ItemKindWarning,
		},
		{
			name:      "assistant then error",
			textEvent: provider.RuntimeEvent{Type: provider.RuntimeEventContentDelta, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "answer"}},
			lastType:  provider.RuntimeEventRuntimeError,
			lastKind:  provider.ItemKindError,
		},
		{
			name:      "reasoning then warning",
			textEvent: provider.RuntimeEvent{Type: provider.RuntimeEventContentDelta, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: "thought"}},
			lastType:  provider.RuntimeEventRuntimeWarning,
			lastKind:  provider.ItemKindWarning,
		},
		{
			name:      "reasoning then error",
			textEvent: provider.RuntimeEvent{Type: provider.RuntimeEventContentDelta, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: "thought"}},
			lastType:  provider.RuntimeEventRuntimeError,
			lastKind:  provider.ItemKindError,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			engine := NewEngine()
			defer engine.Close()
			ingestion := NewProviderRuntimeIngestion(engine)
			threadID := ThreadID("restoring")
			now := time.Now()
			engine.RestoreThreads([]RestoredThread{{ThreadID: threadID, ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now}})
			textEvent := tt.textEvent
			textEvent.ThreadID = string(threadID)
			lastEvent := provider.RuntimeEvent{Type: tt.lastType, ThreadID: string(threadID), Payload: provider.RuntimeEventPayload{Message: "after text"}}

			err := ingestion.RestoreHistory(string(threadID), func() (provider.StartSessionResult, error) {
				return provider.StartSessionResult{Session: provider.Session{ThreadID: string(threadID), ProviderInstanceID: "codex"}, Replay: []provider.RuntimeEvent{textEvent, lastEvent}}, nil
			}, func(provider.Session) {})
			if err != nil {
				t.Fatalf("RestoreHistory: %v", err)
			}

			thread, _ := engine.Thread(threadID)
			if len(thread.Timeline) != 2 {
				t.Fatalf("timeline = %#v, want text then warning/error", thread.Timeline)
			}
			if thread.Timeline[1].Item == nil || thread.Timeline[1].Item.Kind != tt.lastKind {
				t.Fatalf("timeline[1] = %#v, want %s", thread.Timeline[1], tt.lastKind)
			}
			if tt.textEvent.Payload.StreamKind == provider.RuntimeContentAssistantText {
				if thread.Timeline[0].Message == nil || thread.Timeline[0].Message.Text != "answer" {
					t.Fatalf("timeline[0] = %#v, want assistant answer", thread.Timeline[0])
				}
			} else if thread.Timeline[0].Item == nil || thread.Timeline[0].Item.Kind != provider.ItemKindReasoning {
				t.Fatalf("timeline[0] = %#v, want reasoning thought", thread.Timeline[0])
			}
		})
	}
}

func TestIngestionPreservesReplayedConversationOrderWithoutTurnIDs(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-replayed-order")
	now := time.Now()
	engine.RestoreThreads([]RestoredThread{{ThreadID: threadID, ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now}})

	events := []provider.RuntimeEvent{
		{EventID: "user-1", Type: provider.RuntimeEventItemCompleted, ThreadID: string(threadID), ItemID: "user-1", Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, Detail: "first question"}},
		{EventID: "assistant-1", Type: provider.RuntimeEventContentDelta, ThreadID: string(threadID), ItemID: "assistant-1", Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "first answer"}},
		{EventID: "user-2", Type: provider.RuntimeEventItemCompleted, ThreadID: string(threadID), ItemID: "user-2", Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, Detail: "second question"}},
		{EventID: "assistant-2", Type: provider.RuntimeEventContentDelta, ThreadID: string(threadID), ItemID: "assistant-2", Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "second answer"}},
	}
	for _, event := range events {
		ingestion.Ingest(event)
	}
	ingestion.completeHistoryReplay(string(threadID))

	thread, _ := engine.Thread(threadID)
	want := []string{"first question", "first answer", "second question", "second answer"}
	if len(thread.Timeline) != len(want) {
		t.Fatalf("timeline = %#v, want %d messages", thread.Timeline, len(want))
	}
	for index, entry := range thread.Timeline {
		if entry.Message == nil || entry.Message.Text != want[index] {
			t.Fatalf("timeline[%d] = %#v, want message %q", index, entry, want[index])
		}
	}
	if thread.ReplayHistoryPending {
		t.Fatal("replay completion left restored history pending")
	}
}

func TestIngestionPreservesReplayedConversationOrderWithTurnIDs(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-replayed-turn-order")
	now := time.Now()
	engine.RestoreThreads([]RestoredThread{{ThreadID: threadID, ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now}})

	events := []provider.RuntimeEvent{
		{EventID: "user-1", Type: provider.RuntimeEventItemCompleted, ThreadID: string(threadID), TurnID: "turn-1", ItemID: "user-1", Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, Detail: "first question"}},
		{EventID: "assistant-1", Type: provider.RuntimeEventContentDelta, ThreadID: string(threadID), TurnID: "turn-1", ItemID: "assistant-1", Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "first answer"}},
		{EventID: "user-2", Type: provider.RuntimeEventItemCompleted, ThreadID: string(threadID), TurnID: "turn-2", ItemID: "user-2", Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, Detail: "second question"}},
		{EventID: "assistant-2", Type: provider.RuntimeEventContentDelta, ThreadID: string(threadID), TurnID: "turn-2", ItemID: "assistant-2", Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "second answer"}},
		{EventID: "reasoning-2", Type: provider.RuntimeEventContentDelta, ThreadID: string(threadID), TurnID: "turn-2", Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: "second thought"}},
	}
	for _, event := range events {
		ingestion.Ingest(event)
	}
	ingestion.completeHistoryReplay(string(threadID))

	thread, _ := engine.Thread(threadID)
	if len(thread.Timeline) != 5 {
		t.Fatalf("timeline = %#v, want four messages followed by reasoning", thread.Timeline)
	}
	wantMessages := []string{"first question", "first answer", "second question", "second answer"}
	for index, want := range wantMessages {
		entry := thread.Timeline[index]
		if entry.Message == nil || entry.Message.Text != want {
			t.Fatalf("timeline[%d] = %#v, want message %q", index, entry, want)
		}
	}
	reasoning := thread.Timeline[4].Item
	if reasoning == nil || reasoning.Kind != provider.ItemKindReasoning || reasoning.Status != provider.ItemStatusCompleted || reasoning.TurnID != "turn-2" {
		t.Fatalf("timeline[4] = %#v, want completed reasoning for turn-2", thread.Timeline[4])
	}
	ingestion.mu.Lock()
	defer ingestion.mu.Unlock()
	if len(ingestion.turns) != 0 {
		t.Fatalf("replay completion left turn buffers: %#v", ingestion.turns)
	}
	if len(ingestion.turnOrder) != 0 {
		t.Fatalf("replay completion left turn order: %#v", ingestion.turnOrder)
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

	ingestion.completeHistoryReplay(string(threadID))
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

func TestIngestionCoalescesIDLessReplayChunks(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-idless-replay")
	now := time.Now()
	engine.RestoreThreads([]RestoredThread{{ThreadID: threadID, ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now}})

	events := []provider.RuntimeEvent{
		{EventID: "event-1", ThreadID: string(threadID), Type: provider.RuntimeEventItemCompleted, Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, Detail: "first "}},
		{EventID: "event-2", ThreadID: string(threadID), Type: provider.RuntimeEventItemCompleted, Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, Detail: "question"}},
		{EventID: "event-3", ThreadID: string(threadID), Type: provider.RuntimeEventContentDelta, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "first "}},
		{EventID: "event-4", ThreadID: string(threadID), Type: provider.RuntimeEventContentDelta, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "answer"}},
		{EventID: "event-5", ThreadID: string(threadID), Type: provider.RuntimeEventItemCompleted, Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, Detail: "second "}},
		{EventID: "event-6", ThreadID: string(threadID), Type: provider.RuntimeEventItemCompleted, Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, Detail: "question"}},
		{EventID: "event-7", ThreadID: string(threadID), Type: provider.RuntimeEventContentDelta, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "second "}},
		{EventID: "event-8", ThreadID: string(threadID), Type: provider.RuntimeEventContentDelta, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "answer"}},
	}
	for _, event := range events {
		ingestion.Ingest(event)
	}
	ingestion.completeHistoryReplay(string(threadID))

	thread, _ := engine.Thread(threadID)
	want := []string{"first question", "first answer", "second question", "second answer"}
	if len(thread.Timeline) != len(want) {
		t.Fatalf("timeline = %#v, want %d messages", thread.Timeline, len(want))
	}
	for index, entry := range thread.Timeline {
		if entry.Message == nil || entry.Message.Text != want[index] {
			t.Fatalf("timeline[%d] = %#v, want message %q", index, entry, want[index])
		}
	}
	ingestion.mu.Lock()
	defer ingestion.mu.Unlock()
	if len(ingestion.turns) != 0 {
		t.Fatalf("replay completion left turn buffers: %#v", ingestion.turns)
	}
}

func TestIngestionDropsRuntimeEventsFromStaleProviderInstance(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-stale-provider-event")
	newThreadWithSession(t, engine, threadID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-stale-title", Type: provider.RuntimeEventThreadMetadataUpdate, Provider: "test", ProviderInstanceID: "old-instance", ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Title: "stale title"}})
	thread, ok := engine.Thread(threadID)
	if !ok || thread.Title != "Thread" {
		t.Fatalf("thread after stale event = %#v, want title unchanged", thread)
	}

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-current-title", Type: provider.RuntimeEventThreadMetadataUpdate, Provider: "test", ProviderInstanceID: "codex", ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Title: "current title"}})
	thread, ok = engine.Thread(threadID)
	if !ok || thread.Title != "current title" {
		t.Fatalf("thread after current event = %#v, want title updated", thread)
	}

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-switch-provider-for-stale-event", ThreadID: threadID, ProviderInstanceID: "new-instance"}); err != nil {
		t.Fatalf("thread.meta.update provider switch: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "new-instance", Status: SessionStatusReady, UpdatedAt: time.Now()}}}); err != nil {
		t.Fatalf("thread.session.status.set provider switch: %v", err)
	}
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-stale-after-switch", Type: provider.RuntimeEventThreadMetadataUpdate, Provider: "test", ProviderInstanceID: "codex", ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Title: "late old title"}})
	thread, ok = engine.Thread(threadID)
	if !ok || thread.Title != "current title" {
		t.Fatalf("thread after stale event from previous routed instance = %#v, want title unchanged", thread)
	}
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-new-after-switch", Type: provider.RuntimeEventThreadMetadataUpdate, Provider: "test", ProviderInstanceID: "new-instance", ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Title: "new title"}})
	thread, ok = engine.Thread(threadID)
	if !ok || thread.Title != "new title" {
		t.Fatalf("thread after event from switched instance = %#v, want title updated", thread)
	}
}

func TestIngestionDropsTerminalEventFromReplacedGenerationAfterRebind(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-stale-provider-generation")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-stale-provider-generation", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", ProviderGeneration: 2, Status: SessionStatusRunning, ActiveTurnID: "turn-1", UpdatedAt: time.Now()}}}); err != nil {
		t.Fatalf("thread.session.status.set: %v", err)
	}

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

func TestIngestionUsesDesiredProviderAfterProviderSwitchBeforeSessionRebind(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-provider-switch-before-rebind")
	newThreadWithSession(t, engine, threadID)

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-switch-before-rebind", ThreadID: threadID, ProviderInstanceID: "new-instance"}); err != nil {
		t.Fatalf("thread.meta.update provider switch: %v", err)
	}

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-old-before-rebind", Type: provider.RuntimeEventThreadMetadataUpdate, Provider: "test", ProviderInstanceID: "codex", ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Title: "old title"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-new-before-rebind", Type: provider.RuntimeEventThreadMetadataUpdate, Provider: "test", ProviderInstanceID: "new-instance", ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Title: "new title"}})

	thread, ok := engine.Thread(threadID)
	if !ok || thread.Title != "new title" {
		t.Fatalf("thread after provider switch events = %#v, want old instance ignored and new instance accepted", thread)
	}
	if thread.Session != nil {
		t.Fatalf("thread session after provider switch = %#v, want stale session binding cleared before rebind", thread.Session)
	}
}

func TestIngestionRuntimeErrorSetsSessionErrorAndItem(t *testing.T) {
	engine := NewEngine()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-error")
	newThreadWithSession(t, engine, threadID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-err", Type: provider.RuntimeEventRuntimeError, Provider: "test", ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Message: "boom"}})

	thread, ok := engine.Thread(threadID)
	if !ok || thread.Session == nil {
		t.Fatalf("thread/session missing")
	}
	if thread.Session.Status != SessionStatusError || thread.Session.LastError != "boom" {
		t.Fatalf("session = %#v, want error status with lastError", thread.Session)
	}
	var errItem *Item
	for i := range thread.Timeline.Items() {
		if thread.Timeline.Items()[i].Kind == provider.ItemKindError {
			errItem = &thread.Timeline.Items()[i]
		}
	}
	if errItem == nil || errItem.Status != provider.ItemStatusFailed || errItem.Title != "boom" {
		t.Fatalf("items = %#v, want a failed error item", thread.Timeline.Items())
	}
}

func TestIngestionProjectsRuntimeWarningAsWarningItem(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-runtime-warning")
	newThreadWithSession(t, engine, threadID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-warning", Type: provider.RuntimeEventRuntimeWarning, Provider: "test", ThreadID: string(threadID), TurnID: "turn-warning", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Message: "plan mode was not applied"}})

	thread, ok := engine.Thread(threadID)
	if !ok {
		t.Fatalf("thread missing")
	}
	var warning *Item
	for i := range thread.Timeline.Items() {
		if thread.Timeline.Items()[i].Kind == provider.ItemKindWarning {
			warning = &thread.Timeline.Items()[i]
		}
	}
	if warning == nil || warning.ID != "evt-warning" || warning.Status != provider.ItemStatusCompleted || warning.Title != "plan mode was not applied" || warning.TurnID != "turn-warning" {
		t.Fatalf("items = %#v, want completed warning item from runtime warning", thread.Timeline.Items())
	}
	if thread.Session == nil || thread.Session.Status != SessionStatusReady {
		t.Fatalf("session = %#v, warning must not mark the session errored", thread.Session)
	}
}

func TestIngestionFailedTurnCompletionCreatesErrorItem(t *testing.T) {
	engine := NewEngine()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-failed-turn-item")
	newThreadWithSession(t, engine, threadID)
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-failed-turn-item", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-failed-turn-item", Text: "hello"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	turnID := string(thread.LatestTurn.ID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-failed-turn", Type: provider.RuntimeEventTurnCompleted, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnFailed, Message: "provider exploded"}})

	thread, ok := engine.Thread(threadID)
	if !ok || thread.Session == nil || thread.LatestTurn == nil {
		t.Fatalf("thread/session missing: %#v", thread)
	}
	if thread.Session.Status != SessionStatusError || thread.Session.LastError != "provider exploded" || thread.LatestTurn.State != TurnStateError {
		t.Fatalf("thread = %#v, want errored failed turn", thread)
	}
	var errItem *Item
	for i := range thread.Timeline.Items() {
		if thread.Timeline.Items()[i].Kind == provider.ItemKindError {
			errItem = &thread.Timeline.Items()[i]
		}
	}
	if errItem == nil || errItem.Title != "provider exploded" || errItem.Status != provider.ItemStatusFailed || errItem.TurnID != TurnID(turnID) {
		t.Fatalf("items = %#v, want failed turn error item", thread.Timeline.Items())
	}
}

func TestIngestionSettlesReasoningWhenTurnCompletes(t *testing.T) {
	cases := []struct {
		name      string
		turnState provider.RuntimeTurnState
		want      provider.ItemStatus
	}{
		{name: "completed", turnState: provider.RuntimeTurnCompleted, want: provider.ItemStatusCompleted},
		{name: "failed", turnState: provider.RuntimeTurnFailed, want: provider.ItemStatusFailed},
		{name: "interrupted", turnState: provider.RuntimeTurnInterrupted, want: provider.ItemStatusInterrupted},
		{name: "cancelled", turnState: provider.RuntimeTurnCancelled, want: provider.ItemStatusInterrupted},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			engine := NewEngine()
			defer engine.Close()
			ingestion := NewProviderRuntimeIngestion(engine)
			threadID := ThreadID("thread-reasoning-" + tc.name)
			newThreadWithSession(t, engine, threadID)
			if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: CommandID("turn-reasoning-" + tc.name), ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-user", Text: "hello"}, CreatedAt: time.Now()}); err != nil {
				t.Fatalf("thread.turn.start: %v", err)
			}
			thread, _ := engine.Thread(threadID)
			turnID := string(thread.LatestTurn.ID)
			reasoningID := "reasoning:" + string(threadID) + ":" + turnID

			ingestion.Ingest(provider.RuntimeEvent{EventID: provider.RuntimeEventID("evt-reasoning-delta-" + tc.name), Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: "thinking"}})
			ingestion.flushPendingText(time.Now())
			thread, _ = engine.Thread(threadID)
			var item *Item
			for idx := range thread.Timeline.Items() {
				if thread.Timeline.Items()[idx].ID == reasoningID {
					item = &thread.Timeline.Items()[idx]
				}
			}
			if item == nil || item.Status != provider.ItemStatusInProgress {
				t.Fatalf("reasoning item after delta = %#v in items %#v, want in-progress", item, thread.Timeline.Items())
			}

			ingestion.Ingest(provider.RuntimeEvent{EventID: provider.RuntimeEventID("evt-reasoning-complete-" + tc.name), Type: provider.RuntimeEventTurnCompleted, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: tc.turnState, Message: "provider failed"}})

			thread, _ = engine.Thread(threadID)
			item = nil
			for idx := range thread.Timeline.Items() {
				if thread.Timeline.Items()[idx].ID == reasoningID {
					item = &thread.Timeline.Items()[idx]
				}
			}
			if item == nil || item.Status != tc.want {
				t.Fatalf("reasoning item after turn completion = %#v, want status %s", item, tc.want)
			}
			var payload struct {
				Text string `json:"text"`
			}
			if err := json.Unmarshal(item.Payload, &payload); err != nil {
				t.Fatalf("unmarshal reasoning payload: %v", err)
			}
			if payload.Text != "thinking" {
				t.Fatalf("reasoning payload text = %q, want thinking", payload.Text)
			}
		})
	}
}

// A turn that settles abnormally must settle its still-in-progress provider
// items (tool calls): adapters drop post-cancel provider updates, so without
// this an interrupted tool call would stay "inProgress" in the projection
// forever (a spinner the user can never clear). A normally completed turn must
// NOT touch them — the provider is authoritative for its own item outcomes.
func TestIngestionSettlesOpenItemsWhenTurnSettlesAbnormally(t *testing.T) {
	cases := []struct {
		name      string
		turnState provider.RuntimeTurnState
		want      provider.ItemStatus
	}{
		{name: "interrupted", turnState: provider.RuntimeTurnInterrupted, want: provider.ItemStatusInterrupted},
		{name: "cancelled", turnState: provider.RuntimeTurnCancelled, want: provider.ItemStatusInterrupted},
		{name: "failed", turnState: provider.RuntimeTurnFailed, want: provider.ItemStatusFailed},
		{name: "completed", turnState: provider.RuntimeTurnCompleted, want: provider.ItemStatusInProgress},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			engine := NewEngine()
			defer engine.Close()
			ingestion := NewProviderRuntimeIngestion(engine)
			threadID := ThreadID("thread-open-items-" + tc.name)
			newThreadWithSession(t, engine, threadID)
			if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: CommandID("turn-open-items-" + tc.name), ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-user", Text: "hello"}, CreatedAt: time.Now()}); err != nil {
				t.Fatalf("thread.turn.start: %v", err)
			}
			thread, _ := engine.Thread(threadID)
			turnID := string(thread.LatestTurn.ID)

			ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-tool-start", Type: provider.RuntimeEventItemStarted, Provider: "test", ThreadID: string(threadID), TurnID: turnID, ItemID: "tool-open", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution, Title: "run tests"}})
			ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-tool-done-start", Type: provider.RuntimeEventItemStarted, Provider: "test", ThreadID: string(threadID), TurnID: turnID, ItemID: "tool-done", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindFileChange, Title: "edit file"}})
			ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-tool-done-complete", Type: provider.RuntimeEventItemCompleted, Provider: "test", ThreadID: string(threadID), TurnID: turnID, ItemID: "tool-done", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindFileChange}})

			ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-turn-settle", Type: provider.RuntimeEventTurnCompleted, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: tc.turnState}})

			thread, _ = engine.Thread(threadID)
			items := map[string]Item{}
			for _, item := range thread.Timeline.Items() {
				items[item.ID] = item
			}
			open, ok := items["tool-open"]
			if !ok || open.Status != tc.want {
				t.Fatalf("open tool item after %s turn = %#v, want status %s", tc.name, open, tc.want)
			}
			if open.Kind != provider.ItemKindCommandExecution || open.Title != "run tests" {
				t.Fatalf("settled tool item lost kind/title: %#v", open)
			}
			if done := items["tool-done"]; done.Status != provider.ItemStatusCompleted {
				t.Fatalf("provider-settled tool item = %#v, want status preserved as completed", done)
			}
		})
	}
}

func TestIngestionPreservesReasoningToolInterleaving(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-reasoning-tool-order")
	newThreadWithSession(t, engine, threadID)
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-reasoning-tool-order", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-user", Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	turnID := string(thread.LatestTurn.ID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "reasoning-before", Type: provider.RuntimeEventContentDelta, ThreadID: string(threadID), TurnID: turnID, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: "before tool"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "tool-start", ItemID: "tool-1", Type: provider.RuntimeEventItemStarted, ThreadID: string(threadID), TurnID: turnID, Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution, ItemStatus: provider.ItemStatusInProgress, Title: "run tests"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "tool-update", ItemID: "tool-1", Type: provider.RuntimeEventItemUpdated, ThreadID: string(threadID), TurnID: turnID, Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution, Title: "run tests"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "reasoning-after", Type: provider.RuntimeEventContentDelta, ThreadID: string(threadID), TurnID: turnID, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: "after tool"}})
	ingestion.flushPendingText(time.Now())

	thread, _ = engine.Thread(threadID)
	var ordered []*Item
	for _, entry := range thread.Timeline {
		if entry.Item != nil && (entry.Item.Kind == provider.ItemKindReasoning || entry.Item.ID == "tool-1") {
			ordered = append(ordered, entry.Item)
		}
	}
	if len(ordered) != 3 || ordered[0].Kind != provider.ItemKindReasoning || ordered[1].ID != "tool-1" || ordered[2].Kind != provider.ItemKindReasoning {
		t.Fatalf("ordered timeline = %#v, want reasoning, tool, reasoning", ordered)
	}
	if ordered[0].ID == ordered[2].ID {
		t.Fatalf("reasoning segments share id %q, want distinct timeline entries", ordered[0].ID)
	}
	if ordered[1].Status != provider.ItemStatusInProgress {
		t.Fatalf("tool update moved or corrupted tool = %#v", ordered[1])
	}
}

func TestIngestionPreservesAssistantToolInterleaving(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-assistant-tool-order")
	newThreadWithSession(t, engine, threadID)
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-assistant-tool-order", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-user", Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	turnID := string(thread.LatestTurn.ID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "assistant-before", Type: provider.RuntimeEventContentDelta, ThreadID: string(threadID), TurnID: turnID, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "before tool"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "tool-start", ItemID: "tool-1", Type: provider.RuntimeEventItemStarted, ThreadID: string(threadID), TurnID: turnID, Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution, ItemStatus: provider.ItemStatusInProgress}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "assistant-after", Type: provider.RuntimeEventContentDelta, ThreadID: string(threadID), TurnID: turnID, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "after tool"}})
	ingestion.flushPendingText(time.Now())

	thread, _ = engine.Thread(threadID)
	var entries []TimelineEntry
	for _, entry := range thread.Timeline {
		if entry.Item != nil || entry.Message != nil && entry.Message.Role == MessageRoleAssistant {
			entries = append(entries, entry)
		}
	}
	if len(entries) != 3 || entries[0].Message == nil || entries[1].Item == nil || entries[2].Message == nil {
		t.Fatalf("timeline = %#v, want assistant, tool, assistant", entries)
	}
	if entries[0].Message.ID == entries[2].Message.ID {
		t.Fatalf("assistant segments share id %q", entries[0].Message.ID)
	}
}

// Interleaved thinking (OpenAI GPT-5.x emits visible text before and between
// thinking, no tool call required): each switch must start a new timeline entry.
func TestIngestionPreservesReasoningAssistantTextInterleaving(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-reasoning-text-order")
	newThreadWithSession(t, engine, threadID)
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-reasoning-text-order", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-user", Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	turnID := string(thread.LatestTurn.ID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "reasoning-first", Type: provider.RuntimeEventContentDelta, ThreadID: string(threadID), TurnID: turnID, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: "think first"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "assistant-first", Type: provider.RuntimeEventContentDelta, ThreadID: string(threadID), TurnID: turnID, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "answer once"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "reasoning-second", Type: provider.RuntimeEventContentDelta, ThreadID: string(threadID), TurnID: turnID, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: "think again"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "assistant-second", Type: provider.RuntimeEventContentDelta, ThreadID: string(threadID), TurnID: turnID, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "answer twice"}})
	ingestion.flushPendingText(time.Now())

	thread, _ = engine.Thread(threadID)
	var entries []TimelineEntry
	for _, entry := range thread.Timeline {
		if entry.Item != nil && entry.Item.Kind == provider.ItemKindReasoning || entry.Message != nil && entry.Message.Role == MessageRoleAssistant {
			entries = append(entries, entry)
		}
	}
	if len(entries) != 4 || entries[0].Item == nil || entries[1].Message == nil || entries[2].Item == nil || entries[3].Message == nil {
		t.Fatalf("timeline = %#v, want reasoning, assistant, reasoning, assistant", entries)
	}
	if entries[0].Item.ID == entries[2].Item.ID {
		t.Fatalf("reasoning segments share id %q", entries[0].Item.ID)
	}
	if entries[1].Message.ID == entries[3].Message.ID {
		t.Fatalf("assistant segments share id %q", entries[1].Message.ID)
	}
	if entries[1].Message.Text != "answer once" || entries[3].Message.Text != "answer twice" {
		t.Fatalf("assistant texts = %q, %q, want %q, %q", entries[1].Message.Text, entries[3].Message.Text, "answer once", "answer twice")
	}
	if entries[0].Item.Status != provider.ItemStatusCompleted {
		t.Fatalf("first reasoning segment = %#v, want completed", entries[0].Item)
	}
	var payload struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(entries[0].Item.Payload, &payload); err != nil {
		t.Fatalf("unmarshal reasoning payload: %v", err)
	}
	if payload.Text != "think first" {
		t.Fatalf("first reasoning payload text = %q, want %q", payload.Text, "think first")
	}
}

// A provider pause must not hide buffered text: chunks left buffered by the
// interval are flushed by the ingestion ticker, not only by the next chunk or
// semantic boundary (which may be seconds away while the model generates
// tool-call arguments).
func TestIngestionTickerFlushesBufferedAssistantText(t *testing.T) {
	pinFlushInterval(t, 20*time.Millisecond)
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	events := runIngestion(t, ingestion)
	threadID := ThreadID("thread-assistant-deadline")
	newThreadWithSession(t, engine, threadID)

	chunk := func(eventID string, delta string) provider.RuntimeEvent {
		return provider.RuntimeEvent{EventID: provider.RuntimeEventID(eventID), Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), ItemID: "provider-assistant-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: delta}}
	}
	events <- chunk("evt-deadline-1", "he")
	events <- chunk("evt-deadline-2", "llo")

	// No further chunks or boundaries arrive; only the ticker can flush "llo".
	waitFor(t, "ticker flush of the buffered assistant chunk", func() bool {
		thread, ok := engine.Thread(threadID)
		if !ok {
			return false
		}
		messages := thread.Timeline.Messages()
		return len(messages) == 1 && messages[0].Text == "hello"
	})
}

func TestIngestionTickerFlushesBufferedReasoningText(t *testing.T) {
	pinFlushInterval(t, 20*time.Millisecond)
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	events := runIngestion(t, ingestion)
	threadID := ThreadID("thread-reasoning-deadline")
	newThreadWithSession(t, engine, threadID)
	turnID := "turn-reasoning-deadline"
	reasoningID := "reasoning:" + string(threadID) + ":" + turnID

	chunk := func(eventID string, delta string) provider.RuntimeEvent {
		return provider.RuntimeEvent{EventID: provider.RuntimeEventID(eventID), Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: delta}}
	}
	events <- chunk("evt-reasoning-deadline-1", "think")
	events <- chunk("evt-reasoning-deadline-2", "ing")

	waitFor(t, "ticker flush of the buffered reasoning chunk", func() bool {
		thread, ok := engine.Thread(threadID)
		if !ok {
			return false
		}
		for _, item := range thread.Timeline.Items() {
			if item.ID != reasoningID {
				continue
			}
			var payload struct {
				Text string `json:"text"`
			}
			return json.Unmarshal(item.Payload, &payload) == nil && payload.Text == "thinking"
		}
		return false
	})
}

func TestIngestionTickerFlushesConcurrentThreads(t *testing.T) {
	pinFlushInterval(t, 20*time.Millisecond)
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	events := runIngestion(t, ingestion)

	threadIDs := []ThreadID{"thread-ticker-a", "thread-ticker-b", "thread-ticker-c"}
	for _, threadID := range threadIDs {
		newThreadWithSession(t, engine, threadID)
		chunk := func(suffix, delta string) provider.RuntimeEvent {
			return provider.RuntimeEvent{EventID: provider.RuntimeEventID(string(threadID) + suffix), Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: "turn-1", ItemID: "assistant-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: delta}}
		}
		events <- chunk("-first", "hello ")
		events <- chunk("-buffered", string(threadID))
	}

	waitFor(t, "one ticker flush across three active threads", func() bool {
		for _, threadID := range threadIDs {
			thread, ok := engine.Thread(threadID)
			if !ok || len(thread.Timeline.Messages()) != 1 || thread.Timeline.Messages()[0].Text != "hello "+string(threadID) {
				return false
			}
		}
		return true
	})
}

// Reasoning chunks are coalesced: a segment's first chunk flushes immediately
// as a textDelta event (anchoring the item), chunks inside the flush interval
// only accumulate, and the settle checkpoint carries the full text. Per-chunk
// fan-out would flood the event store and every subscribed client.
func TestIngestionCoalescesReasoningChunks(t *testing.T) {
	pinFlushInterval(t, time.Hour)
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-reasoning-delta-size")
	newThreadWithSession(t, engine, threadID)
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-reasoning-delta-size", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-user", Text: "hello"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	turnID := string(thread.LatestTurn.ID)
	reasoningID := "reasoning:" + string(threadID) + ":" + turnID

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-reasoning-chunk-1", Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: "thinking"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-reasoning-chunk-2", Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: " harder"}})

	countReasoningEvents := func() (count int, last *Item) {
		for _, event := range engine.ReplayEvents(ReplayEventsInput{ThreadID: threadID}) {
			if event.Type != EventThreadItemUpserted || event.Payload.Item == nil || event.Payload.Item.ID != reasoningID {
				continue
			}
			count++
			last = event.Payload.Item
		}
		return count, last
	}
	if count, last := countReasoningEvents(); count != 0 {
		t.Fatalf("reasoning events mid-stream = %d (last %#v), want chunks buffered until the ticker or a boundary", count, last)
	}

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-reasoning-settle", Type: provider.RuntimeEventTurnCompleted, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCompleted}})

	count, checkpoint := countReasoningEvents()
	if count != 1 || checkpoint.Status != provider.ItemStatusCompleted {
		t.Fatalf("reasoning events after settle = %d (last %#v), want one completed checkpoint", count, checkpoint)
	}
	thread, _ = engine.Thread(threadID)
	var item *Item
	for idx := range thread.Timeline.Items() {
		if thread.Timeline.Items()[idx].ID == reasoningID {
			item = &thread.Timeline.Items()[idx]
		}
	}
	if item == nil {
		t.Fatalf("reasoning item missing in %#v", thread.Timeline.Items())
	}
	var projected struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(item.Payload, &projected); err != nil {
		t.Fatalf("unmarshal projected reasoning payload: %v", err)
	}
	if projected.Text != "thinking harder" {
		t.Fatalf("projected reasoning text = %q, want %q", projected.Text, "thinking harder")
	}
}

func TestIngestionPlanUpdatedProjectsPlan(t *testing.T) {
	engine := NewEngine()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-plan")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-plan", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}

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
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-prebinding-updates", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-prebinding-config", Type: provider.RuntimeEventConfigOptionsUpdated, Provider: "test", ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ConfigOptions: []provider.ConfigOption{{ID: "model", Category: provider.ConfigOptionCategoryModel, CurrentValue: "fast"}}}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-prebinding-slash", Type: provider.RuntimeEventThreadMetadataUpdate, Provider: "test", ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{SlashCommands: []provider.SlashCommand{{Name: "compact"}}}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-prebinding-usage", Type: provider.RuntimeEventThreadTokenUsage, Provider: "test", ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TokenUsage: &provider.TokenUsage{UsedTokens: 42, MaxTokens: 100}}})

	thread, ok := engine.Thread(threadID)
	if !ok || thread.Session == nil {
		t.Fatalf("thread/session missing after prebinding updates: %#v", thread)
	}
	if len(thread.Session.ConfigOptions) != 1 || len(thread.Session.SlashCommands) != 1 || thread.Session.TokenUsage == nil {
		t.Fatalf("session before binding = %#v, want config, slash commands, and usage", thread.Session)
	}

	// The reactor binds sessions through bound UPDATES; the engine merges the
	// provider identity over the live session, so metadata that arrived
	// before the binding survives.
	if _, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateBound, Binding: &SessionBinding{ProviderInstanceID: "codex"}}); err != nil {
		t.Fatalf("thread.session.status.set bound update: %v", err)
	}
	thread, _ = engine.Thread(threadID)
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

func TestIngestionConfigOptionsProjectOntoSession(t *testing.T) {
	engine := NewEngine()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-config")
	newThreadWithSession(t, engine, threadID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-config", Type: provider.RuntimeEventConfigOptionsUpdated, Provider: "test", ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ConfigOptions: []provider.ConfigOption{
		{ID: "model", Category: provider.ConfigOptionCategoryModel, Label: "Model", CurrentValue: "fast", Choices: []provider.ConfigChoice{{Value: "fast", Label: "Fast"}, {Value: "slow", Label: "Slow"}}},
	}}})

	thread, ok := engine.Thread(threadID)
	if !ok || thread.Session == nil {
		t.Fatalf("thread/session missing")
	}
	if len(thread.Session.ConfigOptions) != 1 || thread.Session.ConfigOptions[0].Category != provider.ConfigOptionCategoryModel || thread.Session.ConfigOptions[0].CurrentValue != "fast" {
		t.Fatalf("config options = %#v, want one model option", thread.Session.ConfigOptions)
	}
}

func TestIngestionEmptyListUpdatesMarshalExplicitArrays(t *testing.T) {
	engine := NewEngine()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-empty-list-json")
	newThreadWithSession(t, engine, threadID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-empty-config", Type: provider.RuntimeEventConfigOptionsUpdated, ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ConfigOptions: []provider.ConfigOption{}}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-empty-slash", Type: provider.RuntimeEventThreadMetadataUpdate, ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{SlashCommands: []provider.SlashCommand{}}})

	var sawConfig, sawSlash bool
	for _, event := range engine.ReplayEvents(ReplayEventsInput{}) {
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
			if string(payload["configOptions"]) != "[]" {
				t.Fatalf("config update payload JSON = %s, want configOptions:[]", raw)
			}
			sawConfig = true
		case EventThreadSlashCommandsUpdated:
			if string(payload["slashCommands"]) != "[]" {
				t.Fatalf("slash update payload JSON = %s, want slashCommands:[]", raw)
			}
			sawSlash = true
		}
	}
	if !sawConfig || !sawSlash {
		t.Fatalf("saw config=%v slash=%v updates, want both", sawConfig, sawSlash)
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

func TestIngestionThreadMetadataAndTokenUsage(t *testing.T) {
	engine := NewEngine()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-meta")
	newThreadWithSession(t, engine, threadID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-cmds", Type: provider.RuntimeEventThreadMetadataUpdate, ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{SlashCommands: []provider.SlashCommand{{Name: "compact", Description: "Compact context"}}}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-title", Type: provider.RuntimeEventThreadMetadataUpdate, ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Title: "Renamed by agent"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-usage", Type: provider.RuntimeEventThreadTokenUsage, ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TokenUsage: &provider.TokenUsage{UsedTokens: 1200, MaxTokens: 200000}}})

	thread, ok := engine.Thread(threadID)
	if !ok || thread.Session == nil {
		t.Fatalf("thread/session missing")
	}
	if len(thread.Session.SlashCommands) != 1 || thread.Session.SlashCommands[0].Name != "compact" {
		t.Fatalf("slash commands = %#v, want one compact command", thread.Session.SlashCommands)
	}
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-cmds-clear", Type: provider.RuntimeEventThreadMetadataUpdate, ThreadID: string(threadID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{SlashCommands: []provider.SlashCommand{}}})
	thread, _ = engine.Thread(threadID)
	if len(thread.Session.SlashCommands) != 0 {
		t.Fatalf("slash commands = %#v, want cleared by empty update", thread.Session.SlashCommands)
	}
	if thread.Title != "Renamed by agent" {
		t.Fatalf("title = %q, want agent rename", thread.Title)
	}
	var titleEvent *Event
	for _, event := range engine.ReplayEvents(ReplayEventsInput{ThreadID: threadID}) {
		if event.Type == EventThreadMetaUpdated && event.Payload.Title == "Renamed by agent" {
			eventCopy := event
			titleEvent = &eventCopy
		}
	}
	if titleEvent == nil || titleEvent.Actor != ActorKindProvider {
		t.Fatalf("title event = %#v, want provider-authored metadata event", titleEvent)
	}
	if thread.Session.TokenUsage == nil || thread.Session.TokenUsage.UsedTokens != 1200 || thread.Session.TokenUsage.MaxTokens != 200000 {
		t.Fatalf("token usage = %#v, want 1200/200000", thread.Session.TokenUsage)
	}
}

func TestIngestionProjectsReplayedProviderUserMessage(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-replayed-user-message")
	newThreadWithSession(t, engine, threadID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-user-1", Type: provider.RuntimeEventItemCompleted, Provider: "test", ThreadID: string(threadID), ItemID: "provider-user-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, ItemStatus: provider.ItemStatusCompleted, Detail: "hello "}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-user-2", Type: provider.RuntimeEventItemCompleted, Provider: "test", ThreadID: string(threadID), ItemID: "provider-user-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, ItemStatus: provider.ItemStatusCompleted, Detail: "again"}})

	thread, ok := engine.Thread(threadID)
	if !ok {
		t.Fatalf("thread missing")
	}
	if len(thread.Timeline.Messages()) != 1 || thread.Timeline.Messages()[0].Role != MessageRoleUser || thread.Timeline.Messages()[0].ID != "user:provider-user-1" || thread.Timeline.Messages()[0].Text != "hello again" {
		t.Fatalf("messages = %#v, want replayed user chunks merged into one user message", thread.Timeline.Messages())
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

func TestIngestionLogsRejectedEventAppend(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-invalid-ingestion")
	newThreadWithSession(t, engine, threadID)

	var logs bytes.Buffer
	previousWriter := log.Writer()
	previousFlags := log.Flags()
	previousPrefix := log.Prefix()
	log.SetOutput(&logs)
	log.SetFlags(0)
	log.SetPrefix("")
	t.Cleanup(func() {
		log.SetOutput(previousWriter)
		log.SetFlags(previousFlags)
		log.SetPrefix(previousPrefix)
	})

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-invalid-approval", Type: provider.RuntimeEventRequestOpened, Provider: "test", ThreadID: string(threadID), CreatedAt: time.Now()})
	if output := logs.String(); !strings.Contains(output, "failed to append ingested event") || !strings.Contains(output, string(EventThreadApprovalOpened)) {
		t.Fatalf("log output = %q, want rejected append context", output)
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
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-assistant-message-ids", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-user", Text: "hello"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	turnID := string(thread.LatestTurn.ID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-msg-1", Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: turnID, ItemID: "provider-msg-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "first"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-msg-2", Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: turnID, ItemID: "provider-msg-2", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "second"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-complete", Type: provider.RuntimeEventTurnCompleted, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCompleted}})

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
}

func TestIngestionIgnoresCancelledCompletionFromPreviousTurn(t *testing.T) {
	engine := NewEngine()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-stale-cancelled-completion")
	newThreadWithSession(t, engine, threadID)
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-stale-old", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-old", Text: "old"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("old thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	oldTurnID := string(thread.LatestTurn.ID)
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnInterrupt, CommandID: "interrupt-stale-old", ThreadID: threadID, TurnID: TurnID(oldTurnID), CreatedAt: time.Now()}); err != nil {
		t.Fatalf("thread.turn.interrupt: %v", err)
	}
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-old-complete", Type: provider.RuntimeEventTurnCompleted, Provider: "test", ThreadID: string(threadID), TurnID: oldTurnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnInterrupted}})
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-stale-new", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-new", Text: "new"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("new thread.turn.start: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	newTurnID := string(thread.LatestTurn.ID)
	if newTurnID == oldTurnID {
		t.Fatalf("new turn reused old turn id %q", oldTurnID)
	}
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-new-complete", Type: provider.RuntimeEventTurnCompleted, Provider: "test", ThreadID: string(threadID), TurnID: newTurnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCompleted}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-old-cancelled", Type: provider.RuntimeEventTurnCompleted, Provider: "test", ThreadID: string(threadID), TurnID: oldTurnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCancelled}})

	thread, _ = engine.Thread(threadID)
	if thread.Session == nil || thread.Session.Status != SessionStatusReady {
		t.Fatalf("session = %#v, want stale old completion ignored after newer turn completed", thread.Session)
	}
	if thread.LatestTurn == nil || thread.LatestTurn.ID != TurnID(newTurnID) || thread.LatestTurn.State != TurnStateCompleted {
		t.Fatalf("latest turn = %#v, want completed newer turn", thread.LatestTurn)
	}
}

func TestIngestionRuntimeErrorForActiveTurnClosesTerminalProviderError(t *testing.T) {
	engine := NewEngine()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-active-runtime-error")
	newThreadWithSession(t, engine, threadID)
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-active-runtime-error", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-user", Text: "hello"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	turnID := string(thread.LatestTurn.ID)

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-active-runtime-error", Type: provider.RuntimeEventRuntimeError, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Message: "provider failed"}})

	thread, _ = engine.Thread(threadID)
	if thread.Session == nil || thread.Session.Status != SessionStatusError || thread.Session.ActiveTurnID != "" || thread.Session.LastError != "provider failed" {
		t.Fatalf("session = %#v, want terminal runtime error", thread.Session)
	}
	if thread.LatestTurn == nil || thread.LatestTurn.State != TurnStateError {
		t.Fatalf("latest turn = %#v, want error", thread.LatestTurn)
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
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-stop-vs-completion")
	newThreadWithSession(t, engine, threadID)
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-stop-vs-completion", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-stop-vs-completion", Text: "hello"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	turnID := string(thread.LatestTurn.ID)
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-started-before-stop", Type: provider.RuntimeEventTurnStarted, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now()})

	// The stop confirmation wins the race with the turn completion.
	if result, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateStopped}); err != nil || result.Sequence == 0 {
		t.Fatalf("stopped update = (%#v, %v), want accepted append", result, err)
	}
	stoppedAt := engine.ReplayEvents(ReplayEventsInput{ThreadID: threadID})
	stoppedSequence := stoppedAt[len(stoppedAt)-1].Sequence

	// The engine must drop the late settle update outright…
	if result, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateTurnSettled, TurnID: TurnID(turnID), TurnState: provider.RuntimeTurnCompleted}); err != nil || result.Sequence != 0 {
		t.Fatalf("late settle update = (%#v, %v), want dropped (no event, no error)", result, err)
	}
	// …and the full ingestion path must reach the same end state.
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-late-completed", Type: provider.RuntimeEventTurnCompleted, Provider: "test", ThreadID: string(threadID), TurnID: turnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCompleted}})

	thread, _ = engine.Thread(threadID)
	if thread.Session == nil || thread.Session.Status != SessionStatusStopped || thread.Session.ActiveTurnID != "" {
		t.Fatalf("session = %#v, want stopped session preserved after late completion", thread.Session)
	}
	if thread.LatestTurn == nil || thread.LatestTurn.ID != TurnID(turnID) || thread.LatestTurn.State != TurnStateInterrupted || thread.LatestTurn.CompletedAt == nil {
		t.Fatalf("latest turn = %#v, want stopped turn to remain interrupted/completed", thread.LatestTurn)
	}
	for _, event := range engine.ReplayEvents(ReplayEventsInput{ThreadID: threadID, FromSequenceExclusive: stoppedSequence}) {
		if event.Type == EventThreadSessionStatusSet {
			t.Fatalf("session status appended after stop: %#v, want late completion dropped", event.Payload.Session)
		}
	}
}

// Regression: a late runtime.error carrying an OLD turn id must not fail the
// thread's CURRENT turn. The old ingestion path had no turn-staleness guard
// on runtime errors, so clients saw error -> complete -> continued streaming;
// the engine now drops turn-scoped error updates whose turn is not the
// current/latest one. The turn-scoped error item still lands in the timeline.
func TestIngestionStaleRuntimeErrorDoesNotFailCurrentTurn(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-stale-runtime-error")
	newThreadWithSession(t, engine, threadID)
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-stale-error-old", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-stale-error-old", Text: "old"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("old thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	oldTurnID := string(thread.LatestTurn.ID)
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-old-settled", Type: provider.RuntimeEventTurnCompleted, Provider: "test", ThreadID: string(threadID), TurnID: oldTurnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnInterrupted}})
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-stale-error-new", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-stale-error-new", Text: "new"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("new thread.turn.start: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	newTurnID := thread.LatestTurn.ID
	if string(newTurnID) == oldTurnID {
		t.Fatalf("new turn reused old turn id %q", oldTurnID)
	}

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-stale-runtime-error", Type: provider.RuntimeEventRuntimeError, Provider: "test", ThreadID: string(threadID), TurnID: oldTurnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Message: "late boom"}})

	thread, _ = engine.Thread(threadID)
	if thread.Session == nil || thread.Session.Status != SessionStatusRunning || thread.Session.ActiveTurnID != newTurnID {
		t.Fatalf("session = %#v, want current turn still running after stale runtime error", thread.Session)
	}
	if thread.LatestTurn == nil || thread.LatestTurn.ID != newTurnID || thread.LatestTurn.State != TurnStateRunning || thread.LatestTurn.Error != "" {
		t.Fatalf("latest turn = %#v, want running current turn unaffected", thread.LatestTurn)
	}
	var errItem *Item
	for idx := range thread.Timeline.Items() {
		if thread.Timeline.Items()[idx].Kind == provider.ItemKindError {
			errItem = &thread.Timeline.Items()[idx]
		}
	}
	if errItem == nil || errItem.TurnID != TurnID(oldTurnID) || errItem.Title != "late boom" {
		t.Fatalf("items = %#v, want stale error kept as a turn-scoped timeline item", thread.Timeline.Items())
	}
}

// Regression: when the engine drops a settle as STALE, ingestion must still
// settle that turn's local streams/buffers — previously a conflicting
// turn.completed returned early, leaving the turn's buffered assistant text
// unflushed and its turns-map entry leaked forever.
func TestIngestionStaleTurnCompletionStillSettlesStreams(t *testing.T) {
	pinFlushInterval(t, time.Hour)
	engine := NewEngine()
	defer engine.Close()
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-stale-settle-buffers")
	newThreadWithSession(t, engine, threadID)
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-stale-buffers-old", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-stale-buffers-old", Text: "old"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("old thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	oldTurnID := string(thread.LatestTurn.ID)
	// The first chunk flushes immediately; the second stays buffered until the
	// stale settle below must flush it.
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-old-delta-1", Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: oldTurnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "par"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-old-delta-2", Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: oldTurnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "tial"}})

	// The old turn settles session-side WITHOUT its runtime settle reaching
	// ingestion (e.g. the terminal event was lost), and a new turn starts.
	if result, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateTurnSettled, TurnID: TurnID(oldTurnID), TurnState: provider.RuntimeTurnInterrupted}); err != nil || result.Sequence == 0 {
		t.Fatalf("old turn settle update = (%#v, %v), want accepted", result, err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-stale-buffers-new", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-stale-buffers-new", Text: "new"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("new thread.turn.start: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	newTurnID := thread.LatestTurn.ID

	// The stale settle for the old turn arrives now: session state must stay
	// on the current turn, but the old turn's streams/buffers must settle.
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-old-stale-complete", Type: provider.RuntimeEventTurnCompleted, Provider: "test", ThreadID: string(threadID), TurnID: oldTurnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCancelled}})

	thread, _ = engine.Thread(threadID)
	if thread.Session == nil || thread.Session.Status != SessionStatusRunning || thread.Session.ActiveTurnID != newTurnID {
		t.Fatalf("session = %#v, want current turn unaffected by stale settle", thread.Session)
	}
	var oldAssistant *Message
	for idx := range thread.Timeline.Messages() {
		if thread.Timeline.Messages()[idx].Role == MessageRoleAssistant && thread.Timeline.Messages()[idx].TurnID == TurnID(oldTurnID) {
			oldAssistant = &thread.Timeline.Messages()[idx]
		}
	}
	if oldAssistant == nil || oldAssistant.Text != "partial" {
		t.Fatalf("old turn assistant message = %#v, want buffered text flushed despite stale settle", oldAssistant)
	}
	ingestion.mu.Lock()
	_, leaked := ingestion.turns[turnKey{threadID: string(threadID), turnID: oldTurnID}]
	ingestion.mu.Unlock()
	if leaked {
		t.Fatal("ingestion turns map still holds the stale-settled turn, want buffers cleared")
	}
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
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-older-buffers-old", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-older-buffers-old", Text: "old"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("old thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	oldTurnID := string(thread.LatestTurn.ID)
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-older-delta-1", Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: oldTurnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "orph"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-older-delta-2", Type: provider.RuntimeEventContentDelta, Provider: "test", ThreadID: string(threadID), TurnID: oldTurnID, CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "aned"}})

	if result, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateTurnSettled, TurnID: TurnID(oldTurnID), TurnState: provider.RuntimeTurnInterrupted}); err != nil || result.Sequence == 0 {
		t.Fatalf("old turn settle update = (%#v, %v), want accepted", result, err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-older-buffers-new", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-older-buffers-new", Text: "new"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("new thread.turn.start: %v", err)
	}
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
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-item", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}

	// Providers send the COMPLETE tool-call state on every event (the ACP
	// adapter accumulates sparse updates itself); the projected payload is a
	// replacement of the previous one, and a data-less status update keeps it.
	startData := json.RawMessage(`{"toolCallId":"tool-1","content":[{"type":"terminal","command":"go test ./..."}],"locations":[{"path":"main.go"}],"status":"pending"}`)
	doneData := json.RawMessage(`{"toolCallId":"tool-1","content":[{"type":"terminal","command":"go test ./..."}],"locations":[{"path":"main.go"}],"status":"completed"}`)
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-item-start", Type: provider.RuntimeEventItemStarted, Provider: "test", ThreadID: string(threadID), TurnID: "turn-1", ItemID: "tool-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution, Title: "run tests", Data: startData}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-item-done", Type: provider.RuntimeEventItemCompleted, Provider: "test", ThreadID: string(threadID), TurnID: "turn-1", ItemID: "tool-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution, Data: doneData}})
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
	var payload struct {
		Data map[string]json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(item.Payload, &payload); err != nil {
		t.Fatalf("unmarshal item payload: %v", err)
	}
	if string(payload.Data["status"]) != `"completed"` || string(payload.Data["locations"]) != `[{"path":"main.go"}]` {
		t.Fatalf("item payload = %s, want the completed event's full data as the replacement payload", item.Payload)
	}

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-item-interrupted", Type: provider.RuntimeEventItemUpdated, Provider: "test", ThreadID: string(threadID), TurnID: "turn-1", ItemID: "tool-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution, ItemStatus: provider.ItemStatusInterrupted}})
	thread, _ = engine.Thread(threadID)
	item = thread.Timeline.Items()[0]
	if item.Status != provider.ItemStatusInterrupted || item.Kind != provider.ItemKindCommandExecution || item.Title != "run tests" || string(item.Payload) == "" {
		t.Fatalf("interrupted item = %#v, want interrupted status preserving kind, title, and completed payload", item)
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
	ingestion := NewProviderRuntimeIngestion(engine)
	threadID := ThreadID("thread-reasoning-content")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-reasoning-content", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
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
	for _, event := range engine.ReplayEvents(ReplayEventsInput{ThreadID: threadID}) {
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
