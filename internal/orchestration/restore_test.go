package orchestration

import (
	"context"
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
