package daemon

// Terminal list tests: the list stream, identity persistence, and the
// rename/delete actions.

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/provider"
)

func subscribeTerminalListSnapshot(t *testing.T, c *recordingClient) wire.TerminalListStreamItem {
	t.Helper()
	var snapshot wire.TerminalListStreamItem
	c.call(t, wire.MethodTerminalSubscribeList, wire.EmptyParams{}, &snapshot)
	if snapshot.Kind != wire.TerminalListItemSnapshot {
		t.Fatalf("subscribeList kind = %s, want snapshot", snapshot.Kind)
	}
	return snapshot
}

// waitForListItem consumes list notifications in arrival order until one
// matches, so successive waits observe successive items.
func waitForListItem(t *testing.T, c *recordingClient, desc string, match func(wire.TerminalListStreamItem) bool) wire.TerminalListStreamItem {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		for c.terminalListCursor < len(c.terminalListItems) {
			item := c.terminalListItems[c.terminalListCursor]
			c.terminalListCursor++
			if match(item) {
				c.mu.Unlock()
				return item
			}
		}
		c.mu.Unlock()
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for terminal list %s", desc)
	return wire.TerminalListStreamItem{}
}

func waitForListUpsert(t *testing.T, c *recordingClient, match func(wire.TerminalSummary) bool) wire.TerminalSummary {
	t.Helper()
	return *waitForListItem(t, c, "upsert", func(item wire.TerminalListStreamItem) bool {
		return item.Kind == wire.TerminalListItemUpserted && item.Terminal != nil && match(*item.Terminal)
	}).Terminal
}

func TestTerminalListSnapshotAndLifecycleUpserts(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)

	observer := dialRecordingClient(t, url)
	if snapshot := subscribeTerminalListSnapshot(t, observer); len(snapshot.Terminals) != 0 {
		t.Fatalf("initial snapshot has %d terminals, want 0", len(snapshot.Terminals))
	}

	controller := dialRecordingClient(t, url)
	created := createTestTerminal(t, controller)
	terminalID := created.Terminal.TerminalID

	// Create publishes one upsert to the observer.
	summary := waitForListUpsert(t, observer, func(s wire.TerminalSummary) bool {
		return s.TerminalID == terminalID
	})
	if summary.Cwd == "" {
		t.Fatal("list summary missing cwd")
	}

	// Rename returns and publishes the new title with a bumped updatedAt.
	var renamed wire.TerminalSummary
	observer.call(t, wire.MethodTerminalRename, wire.TerminalRenameParams{
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
	controller.writeTerminal(t, terminalID, "printf 'NOISE-%d\\n' $((3+4))\n")
	controller.waitForOutput(t, "NOISE-7")
	if after := len(observer.listItemsSnapshot()); after != before {
		t.Fatalf("raw output published %d list updates", after-before)
	}

	// Delete removes the row, publishes a removal, and ends the stream.
	observer.call(t, wire.MethodTerminalDelete, wire.TerminalIDParams{TerminalID: terminalID}, nil)
	if code := created.stream.waitClosed(t); code != websocket.StatusNormalClosure {
		t.Fatalf("delete closed the stream with %v, want %v", code, websocket.StatusNormalClosure)
	}
	waitForListItem(t, observer, "removal", func(item wire.TerminalListStreamItem) bool {
		return item.Kind == wire.TerminalListItemRemoved && item.TerminalID == terminalID
	})
	// The identity is gone: attach and rename both fail.
	if _, err := observer.attachTerminal(terminalID, 80, 24); err == nil {
		t.Fatal("attach to deleted terminal succeeded")
	}
	if err := observer.callErr(wire.MethodTerminalRename, wire.TerminalRenameParams{TerminalID: terminalID, Title: "ghost"}, nil); err == nil {
		t.Fatal("rename of deleted terminal succeeded")
	}
}

// After a daemon restart a saved terminal has no shell until someone opens it.
// Devices come back by attaching, together or in any order, and share one fresh
// shell at the grid they asked for.
func TestTerminalRestartStartsAFreshShellWhenOpened(t *testing.T) {
	useQuietTestShell(t)
	dir := t.TempDir()
	s := newTestServerAt(t, dir)
	client := dialRecordingClient(t, newWSTestServer(t, s))

	created := createTestTerminal(t, client)
	terminalID := created.Terminal.TerminalID
	client.call(t, wire.MethodTerminalRename, wire.TerminalRenameParams{TerminalID: terminalID, Title: "Survivor"}, nil)
	unopened := createTestTerminal(t, client).Terminal.TerminalID
	// A distinctive marker proves later that no pre-restart output can reach
	// a post-restart attach.
	client.writeTerminal(t, terminalID, "printf 'OLD-RUN-%d\\n' $((100+23))\n")
	client.waitForOutput(t, "OLD-RUN-123")
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	if code := created.stream.waitClosed(t); code != websocket.StatusGoingAway {
		t.Fatalf("shutdown closed the stream with %v, want %v", code, websocket.StatusGoingAway)
	}

	restarted := newTestServerAt(t, dir)
	url := newWSTestServer(t, restarted)
	laptop, phone := dialRecordingClient(t, url), dialRecordingClient(t, url)

	if rows := subscribeTerminalListSnapshot(t, laptop).Terminals; len(rows) != 2 {
		t.Fatalf("restarted list = %+v, want both saved terminals", rows)
	}
	if _, err := restarted.terminals.service.Get(terminalID); err == nil {
		t.Fatal("the shell started before anyone opened the terminal")
	}
	// One never opened again can still be deleted.
	laptop.call(t, wire.MethodTerminalDelete, wire.TerminalIDParams{TerminalID: unopened}, nil)
	rows := subscribeTerminalListSnapshot(t, phone).Terminals
	if len(rows) != 1 || rows[0].TerminalID != terminalID || rows[0].Title != "Survivor" {
		t.Fatalf("list after the delete = %+v, want the renamed terminal", rows)
	}

	var attaches sync.WaitGroup
	var onLaptop, onPhone wire.TerminalAttachResult
	var laptopErr, phoneErr error
	attaches.Go(func() { onLaptop, laptopErr = laptop.attachTerminal(terminalID, 96, 31) })
	attaches.Go(func() { onPhone, phoneErr = phone.attachTerminal(terminalID, 96, 31) })
	attaches.Wait()
	if laptopErr != nil || phoneErr != nil {
		t.Fatalf("attach errors: %v, %v", laptopErr, phoneErr)
	}
	laptopView, phoneView := laptop.view(t, onLaptop), phone.view(t, onPhone)
	if containsBytes(laptopView.Snapshot, "OLD-RUN-123") || containsBytes(phoneView.Snapshot, "OLD-RUN-123") {
		t.Fatal("old output survived the daemon restart")
	}
	phone.writeTerminal(t, terminalID, "printf 'FRESH-%s-END\\n' \"$(stty size | tr ' ' 'x')\"\n")
	laptopView.stream.waitOutput(t, 1, "FRESH-31x96-END")
	phoneView.stream.waitOutput(t, 1, "FRESH-31x96-END")
}

// A saved terminal whose folder is gone opens from the home directory. One whose
// shell can't start at all fails the attach, stays listed, and opens once it can.
func TestTerminalOpensFromHomeWhenItsFolderIsGone(t *testing.T) {
	useQuietTestShell(t)
	home := filepath.Join(t.TempDir(), "home")
	t.Setenv("HOME", home)
	dir := t.TempDir()
	folder := t.TempDir()
	s := newTestServerAt(t, dir)
	client := dialRecordingClient(t, newWSTestServer(t, s))
	var created wire.TerminalAttachResult
	client.call(t, wire.MethodTerminalCreate, wire.TerminalCreateParams{Cwd: folder, Columns: 80, Rows: 24, Appearance: testAppearance}, &created)
	terminalID := created.Terminal.TerminalID
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	if err := os.RemoveAll(folder); err != nil {
		t.Fatal(err)
	}

	restarted := newTestServerAt(t, dir)
	client = dialRecordingClient(t, newWSTestServer(t, restarted))
	if _, err := client.attachTerminal(terminalID, 80, 24); err == nil {
		t.Fatal("attach succeeded with neither the folder nor a home directory")
	}
	if rows := subscribeTerminalListSnapshot(t, client).Terminals; len(rows) != 1 || rows[0].Cwd != folder {
		t.Fatalf("list after the failed attach = %+v, want the terminal in %s", rows, folder)
	}

	if err := os.Mkdir(home, 0o755); err != nil {
		t.Fatal(err)
	}
	view := client.mustAttachTerminal(t, terminalID, 80, 24)
	if view.Terminal.Cwd != home {
		t.Fatalf("cwd = %s, want %s", view.Terminal.Cwd, home)
	}
	resolved, err := filepath.EvalSymlinks(home)
	if err != nil {
		t.Fatal(err)
	}
	client.writeTerminal(t, terminalID, "printf 'IN[%s]END\\n' \"$(pwd -P)\"\n")
	view.stream.waitOutput(t, 1, "IN["+resolved+"]END")
	if err := restarted.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	client = dialRecordingClient(t, newWSTestServer(t, newTestServerAt(t, dir)))
	if rows := subscribeTerminalListSnapshot(t, client).Terminals; len(rows) != 1 || rows[0].Cwd != home {
		t.Fatalf("list after another restart = %+v, want the terminal in %s", rows, home)
	}
}

// A terminal running a one-off program, as a sign-in does, doesn't come back
// after a restart: there's no shell to give it, even if it was renamed.
func TestTerminalRunningACommandIsNotRestored(t *testing.T) {
	dir := t.TempDir()
	s := newTestServerAt(t, dir)
	client := dialRecordingClient(t, newWSTestServer(t, s))
	terminalID, err := s.startCommandTerminal("Sign in", provider.TerminalCommand{Argv: []string{"/bin/sleep", "600"}}, func(*int) {})
	if err != nil {
		t.Fatal(err)
	}
	client.call(t, wire.MethodTerminalRename, wire.TerminalRenameParams{TerminalID: terminalID, Title: "Renamed"}, nil)
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	client = dialRecordingClient(t, newWSTestServer(t, newTestServerAt(t, dir)))
	if rows := subscribeTerminalListSnapshot(t, client).Terminals; len(rows) != 0 {
		t.Fatalf("restarted list = %+v, want none", rows)
	}
}
