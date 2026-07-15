package orchestration

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

func TestRestoreThreadsSeedsSidebarStubs(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()

	created := time.Date(2026, 7, 1, 10, 0, 0, 0, time.UTC)
	updated := created.Add(2 * time.Hour)
	engine.RestoreThreads([]RestoredThread{
		{
			ThreadID:           "thread-restored",
			Title:              "Restored thread",
			Cwd:                "/tmp",
			ProviderInstanceID: "codex",
			ModelSelection:     &provider.ModelSelection{Model: "gpt"},
			CreatedAt:          created,
			UpdatedAt:          updated,
		},
		{ThreadID: "thread-untitled", CreatedAt: created, UpdatedAt: created},
	})

	list := engine.ThreadListSnapshot()
	if len(list.Snapshot.Threads) != 2 {
		t.Fatalf("thread list = %#v, want 2 restored stubs", list.Snapshot.Threads)
	}
	entry, ok := engine.ThreadListEntry("thread-restored")
	if !ok {
		t.Fatal("restored thread missing from projection")
	}
	if entry.Title != "Restored thread" || entry.Cwd != "/tmp" || entry.ProviderInstanceID != "codex" {
		t.Fatalf("restored entry = %#v, want persisted sidebar fields", entry)
	}
	if entry.ModelSelection == nil || entry.ModelSelection.Model != "gpt" {
		t.Fatalf("restored model selection = %#v, want gpt", entry.ModelSelection)
	}
	if !entry.CreatedAt.Equal(created) || !entry.UpdatedAt.Equal(updated) {
		t.Fatalf("restored timestamps = %v/%v, want the stored %v/%v", entry.CreatedAt, entry.UpdatedAt, created, updated)
	}
	if entry.Session != nil {
		t.Fatalf("restored stub must have no session binding, got %#v", entry.Session)
	}
	if entry.Draft {
		t.Fatalf("restored entry = %#v, want non-draft", entry)
	}
	if untitled, _ := engine.ThreadListEntry("thread-untitled"); untitled.Title != "Untitled thread" {
		t.Fatalf("empty title = %q, want default", untitled.Title)
	}

	snapshot, err := engine.ThreadSnapshot("thread-restored")
	if err != nil {
		t.Fatalf("ThreadSnapshot: %v", err)
	}
	if len(snapshot.Snapshot.Thread.Timeline) != 0 {
		t.Fatalf("restored timeline = %#v, want empty (history is provider-owned)", snapshot.Snapshot.Thread.Timeline)
	}
	if snapshot.Snapshot.Thread.Draft {
		t.Fatalf("restored thread = %#v, want non-draft", snapshot.Snapshot.Thread)
	}

	// A restart is a new epoch: restore appends nothing to the event log, so
	// clients resnapshot instead of replaying restored threads into existence.
	if replay := engine.ReplayEvents(ReplayEventsInput{}); len(replay) != 0 {
		t.Fatalf("restore appended events: %#v", replay)
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
	tests := []struct {
		name   string
		status SessionStatus
	}{
		{name: "starting", status: SessionStatusStarting},
		{name: "error", status: SessionStatusError},
		{name: "stopped", status: SessionStatusStopped},
		{name: "interrupted", status: SessionStatusInterrupted},
		{name: "ready", status: SessionStatusReady},
		{name: "running", status: SessionStatusRunning},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			engine := NewEngine()
			defer engine.Close()
			now := time.Now()
			engine.RestoreThreads([]RestoredThread{{ThreadID: "thread-restored", ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now}})

			if _, err := engine.AppendEvent(context.Background(), EventInput{
				Type:     EventThreadSessionStatusSet,
				ThreadID: "thread-restored",
				Payload:  EventPayload{Session: &SessionBinding{Status: tt.status}},
			}); err != nil {
				t.Fatalf("append session status: %v", err)
			}
			thread, _ := engine.Thread("thread-restored")
			if !thread.ReplayHistoryPending {
				t.Fatalf("session status %s consumed replay intent", tt.status)
			}
			if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadHistoryReplayCompleted, ThreadID: "thread-restored"}); err != nil {
				t.Fatalf("append replay completion: %v", err)
			}
			thread, _ = engine.Thread("thread-restored")
			if thread.ReplayHistoryPending {
				t.Fatal("replay completion did not consume replay intent")
			}
		})
	}
}
