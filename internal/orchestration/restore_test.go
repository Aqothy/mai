package orchestration

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestImportThreadPublishesReplayPendingStub(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	var events []Event
	engine.OnEvent(func(event Event) { events = append(events, event) })

	result, err := engine.ImportThread(context.Background(), RestoredThread{
		ThreadID:           "thread-imported",
		Title:              "Imported session",
		Cwd:                t.TempDir(),
		ProviderInstanceID: "codex",
		CreatedAt:          now,
		UpdatedAt:          now,
	})
	if err != nil {
		t.Fatalf("ImportThread: %v", err)
	}
	thread, ok := engine.projection.Thread("thread-imported")
	if !ok || !thread.ReplayHistoryPending || len(thread.Timeline) != 0 {
		t.Fatalf("imported thread = %+v, want empty replay-pending stub", thread)
	}
	if !thread.CreatedAt.Equal(now) || !thread.UpdatedAt.Equal(now) {
		t.Fatalf("imported timestamps = (%v, %v), want %v", thread.CreatedAt, thread.UpdatedAt, now)
	}
	if len(events) != 1 || events[0].Type != EventThreadImported || events[0].Sequence != result.Sequence {
		t.Fatalf("import events = %+v, want one thread.imported event", events)
	}
}

func TestRestoreThreadsNeverOverwritesAndCreateStaysIdempotent(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	now := time.Now()
	engine.RestoreThreads([]RestoredThread{{ThreadID: "thread-1", Title: "Restored", Cwd: t.TempDir(), CreatedAt: now, UpdatedAt: now}})

	// A client retrying thread.create against its restored thread is a no-op.
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, ThreadID: "thread-1", Title: "Client copy", Cwd: t.TempDir()}); err != nil {
		t.Fatalf("thread.create on restored thread: %v", err)
	}
	entry, ok := engine.ThreadListEntry("thread-1")
	if !ok || entry.Title != "Restored" {
		t.Fatalf("entry = %#v, want restored stub kept", entry)
	}

	// Restoring over a live thread leaves it untouched.
	engine.RestoreThreads([]RestoredThread{{ThreadID: "thread-1", Title: "Stale copy", CreatedAt: now, UpdatedAt: now}})
	if entry, _ := engine.ThreadListEntry("thread-1"); entry.Title != "Restored" {
		t.Fatalf("restore overwrote a live thread: %#v", entry)
	}
}

func TestRestoredThreadRequiresPreparationBeforeTurnStart(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	now := time.Now()
	engine.RestoreThreads([]RestoredThread{{
		ThreadID:           "thread-restored",
		ProviderInstanceID: "codex",
		CreatedAt:          now,
		UpdatedAt:          now,
	}})

	_, err := engine.Dispatch(context.Background(), Command{
		Type:      CommandThreadTurnStart,
		CommandID: "turn-before-prepare",
		ThreadID:  "thread-restored",
		Message:   &CommandMessage{MessageID: "message-before-prepare", Text: "hello"},
	})
	if err == nil || !strings.Contains(err.Error(), "before preparing") {
		t.Fatalf("thread.turn.start err = %v, want preparation requirement", err)
	}
	thread, _ := engine.Thread("thread-restored")
	if len(thread.Timeline) != 0 || thread.LatestTurn != nil {
		t.Fatalf("rejected turn mutated restored thread: %#v", thread)
	}
}

func TestRestoredReplayIntentClearsOnlyAfterReplayCompletes(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	now := time.Now()
	engine.RestoreThreads([]RestoredThread{{ThreadID: "thread-restored", ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now}})

	// Readiness is the tempting but incorrect point at which to consume the
	// intent: only the explicit replay-completed fact owns that transition.
	if _, err := engine.AppendEvent(context.Background(), EventInput{
		Type:     EventThreadSessionStatusSet,
		ThreadID: "thread-restored",
		Payload:  EventPayload{Session: &SessionBinding{Status: SessionStatusReady}},
	}); err != nil {
		t.Fatalf("append ready session status: %v", err)
	}
	thread, _ := engine.Thread("thread-restored")
	if !thread.ReplayHistoryPending {
		t.Fatal("ready session status consumed replay intent")
	}
	// Partially replayed history is still not the complete restore.
	if _, err := engine.AppendEvent(context.Background(), EventInput{
		Type:     EventThreadMessageSent,
		ThreadID: "thread-restored",
		Payload:  EventPayload{MessageID: "restored-message", Role: MessageRoleUser, Text: "partially restored"},
	}); err != nil {
		t.Fatalf("append partial restored history: %v", err)
	}
	pending, err := engine.SubscribeThread(SubscribeThreadInput{ThreadID: "thread-restored"})
	if err != nil {
		t.Fatalf("subscribe pending restored thread: %v", err)
	}
	if !pending.Snapshot.HistoryRestorePending || len(pending.Snapshot.Thread.Timeline) != 1 {
		t.Fatalf("partially restored snapshot = %#v, want pending with the partial timeline", pending.Snapshot)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadHistoryReplayCompleted, ThreadID: "thread-restored"}); err != nil {
		t.Fatalf("append replay completion: %v", err)
	}
	thread, _ = engine.Thread("thread-restored")
	if thread.ReplayHistoryPending {
		t.Fatal("replay completion did not consume replay intent")
	}
	ready, err := engine.SubscribeThread(SubscribeThreadInput{ThreadID: "thread-restored"})
	if err != nil {
		t.Fatalf("subscribe restored thread after completion: %v", err)
	}
	if ready.Snapshot.HistoryRestorePending {
		t.Fatal("snapshot kept provider history pending after replay completion")
	}
}
