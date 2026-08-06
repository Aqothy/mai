package daemon

// Increment 5 tests: the terminal list stream, identity persistence, and the
// rename/terminate/delete actions.

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/store"
	"github.com/Aqothy/maiD/internal/terminal"
)

func subscribeTerminalListSnapshot(t *testing.T, c *terminalTestClient) wire.TerminalListStreamItem {
	t.Helper()
	var snapshot wire.TerminalListStreamItem
	c.call(t, RPCMethodTerminalSubscribeList, wire.EmptyParams{}, &snapshot)
	if snapshot.Kind != wire.TerminalListItemSnapshot {
		t.Fatalf("subscribeList kind = %s, want snapshot", snapshot.Kind)
	}
	return snapshot
}

func waitForListUpsert(t *testing.T, c *terminalTestClient, match func(wire.TerminalSummary) bool) wire.TerminalSummary {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		for _, item := range c.listItemsSnapshot() {
			if item.Kind == wire.TerminalListItemUpserted && item.Terminal != nil && match(*item.Terminal) {
				return *item.Terminal
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("timed out waiting for terminal list upsert")
	return wire.TerminalSummary{}
}

func TestTerminalListSnapshotAndLifecycleUpserts(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)

	observer := dialTerminalClient(t, url)
	if snapshot := subscribeTerminalListSnapshot(t, observer); len(snapshot.Terminals) != 0 {
		t.Fatalf("initial snapshot has %d terminals, want 0", len(snapshot.Terminals))
	}

	controller := dialTerminalClient(t, url)
	created := createTestTerminal(t, controller)
	terminalID := created.Terminal.TerminalID

	// Create publishes one running upsert to the observer.
	summary := waitForListUpsert(t, observer, func(s wire.TerminalSummary) bool {
		return s.TerminalID == terminalID && s.Status == terminal.StatusRunning
	})
	if summary.Cwd == "" {
		t.Fatal("list summary missing cwd")
	}

	// Rename returns and publishes the new title with a bumped updatedAt.
	var renamed wire.TerminalSummary
	observer.call(t, RPCMethodTerminalRename, wire.TerminalRenameParams{
		TerminalID: terminalID,
		Title:      "Build terminal",
	}, &renamed)
	if renamed.Title != "Build terminal" {
		t.Fatalf("rename title = %q", renamed.Title)
	}
	if !renamed.UpdatedAt.After(summary.UpdatedAt) {
		t.Fatal("rename did not bump updatedAt")
	}
	waitForListUpsert(t, observer, func(s wire.TerminalSummary) bool {
		return s.Title == "Build terminal"
	})

	// Ordinary output must not publish list updates or bump updatedAt.
	before := len(observer.listItemsSnapshot())
	controller.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      created.RunID,
		Data:       []byte("printf 'NOISE-%d\\n' $((3+4))\n"),
	})
	controller.waitForOutput(t, "NOISE-7")
	if after := len(observer.listItemsSnapshot()); after != before {
		t.Fatalf("raw output published %d list updates", after-before)
	}

	// Terminate publishes a stopped upsert without changing updatedAt.
	observer.call(t, RPCMethodTerminalTerminate, wire.TerminalIDParams{TerminalID: terminalID}, nil)
	stopped := waitForListUpsert(t, observer, func(s wire.TerminalSummary) bool {
		return s.TerminalID == terminalID && s.Status == terminal.StatusStopped
	})
	if !stopped.UpdatedAt.Equal(renamed.UpdatedAt) {
		t.Fatal("terminate changed updatedAt")
	}

	// Delete removes the row and publishes a removal.
	observer.call(t, RPCMethodTerminalDelete, wire.TerminalIDParams{TerminalID: terminalID}, nil)
	deadline := time.Now().Add(15 * time.Second)
	for {
		removed := false
		for _, item := range observer.listItemsSnapshot() {
			if item.Kind == wire.TerminalListItemRemoved && item.TerminalID == terminalID {
				removed = true
			}
		}
		if removed {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for terminal removal")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestTerminalMetadataSurvivesDaemonRestartAsStopped(t *testing.T) {
	useQuietTestShell(t)
	path := filepath.Join(t.TempDir(), "maid.db")
	metadata, err := store.Open(path)
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	s := newServer(newLoggerFromEnv(), metadata)
	url := newWSTestServer(t, s)
	client := dialTerminalClient(t, url)

	created := createTestTerminal(t, client)
	client.call(t, RPCMethodTerminalRename, wire.TerminalRenameParams{
		TerminalID: created.Terminal.TerminalID,
		Title:      "Survivor",
	}, nil)
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	metadata2, err := store.Open(path)
	if err != nil {
		t.Fatalf("reopen store: %v", err)
	}
	restarted := newServer(newLoggerFromEnv(), metadata2)
	defer restarted.Close()
	url2 := newWSTestServer(t, restarted)
	client2 := dialTerminalClient(t, url2)

	snapshot := subscribeTerminalListSnapshot(t, client2)
	if len(snapshot.Terminals) != 1 {
		t.Fatalf("restarted snapshot has %d terminals, want 1", len(snapshot.Terminals))
	}
	restored := snapshot.Terminals[0]
	if restored.TerminalID != created.Terminal.TerminalID || restored.Title != "Survivor" {
		t.Fatalf("restored summary mismatch: %+v", restored)
	}
	if restored.Status != terminal.StatusStopped {
		t.Fatalf("restored status = %s, want stopped", restored.Status)
	}

	// The old run's process and output are gone by design: attach requires a
	// relaunch, which starts a fresh shell in the persisted cwd.
	if _, err := attachOnce(client2, restored.TerminalID); err == nil {
		t.Fatal("attach to stopped terminal succeeded, want relaunch requirement")
	}
	var relaunched wire.TerminalAttachSnapshot
	client2.call(t, RPCMethodTerminalRelaunch, wire.TerminalAttachParams{
		TerminalID: restored.TerminalID,
		Columns:    80,
		Rows:       24,
	}, &relaunched)
	if relaunched.RunID == created.RunID {
		t.Fatal("relaunch after restart reused the old run id")
	}
	if len(relaunched.Replay) != 0 {
		t.Fatal("old output survived the daemon restart")
	}
}

func TestTerminalDeleteWhileRunningTerminatesProcess(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	client := dialTerminalClient(t, url)

	created := createTestTerminal(t, client)
	client.call(t, RPCMethodTerminalDelete, wire.TerminalIDParams{TerminalID: created.Terminal.TerminalID}, nil)

	// The identity is gone: attach and rename both fail.
	if _, err := attachOnce(client, created.Terminal.TerminalID); err == nil {
		t.Fatal("attach to deleted terminal succeeded")
	}
	var renamed wire.TerminalSummary
	ctx, cancel := timeout15()
	defer cancel()
	if err := client.conn.Call(ctx, RPCMethodTerminalRename, wire.TerminalRenameParams{
		TerminalID: created.Terminal.TerminalID,
		Title:      "ghost",
	}).Await(ctx, &renamed); err == nil {
		t.Fatal("rename of deleted terminal succeeded")
	}
}
