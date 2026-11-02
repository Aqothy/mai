package daemon

// Terminal lifecycle tests: reattach snapshot ordering, detach without
// termination, and shared multi-client attachment, all through real WebSocket
// clients.

import (
	"bytes"
	"context"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/Aqothy/maiD/api/wire"
)

func resizedTo(columns, rows uint16) func(testRecord) bool {
	return func(record testRecord) bool {
		return record.kind == wire.TerminalRecordResized && record.resized == wire.TerminalStreamResized{Columns: columns, Rows: rows}
	}
}

func TestTerminalReattachReceivesSnapshotThenLive(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	first := dialRecordingClient(t, url)

	snapshot := createTestTerminal(t, first)
	terminalID := snapshot.Terminal.TerminalID
	first.writeTerminal(t, terminalID, "printf 'HISTORY-%d\\n' $((80+8))\n")
	first.waitForOutput(t, "HISTORY-88")

	second := dialRecordingClient(t, url)
	attach := second.mustAttachTerminal(t, terminalID, 96, 31)
	// The Ghostty commit the daemon links.
	const wantFormat = "ghostty-gsn-v1-f54340ad77814fe319d136e5e915d6a48de8dd23"
	if attach.SnapshotFormat != wantFormat {
		t.Fatalf("snapshot format = %q, want %q", attach.SnapshotFormat, wantFormat)
	}
	if !containsBytes(attach.Snapshot, "HISTORY-88") {
		t.Fatal("attach snapshot missing output produced before attach")
	}

	// The new listener can write, and its stream carries the output.
	second.writeTerminal(t, terminalID, "printf 'LIVE-%d\\n' $((60+6))\n")
	attach.stream.waitOutput(t, 1, "LIVE-66")
}

func TestTerminalMultipleAttachedClientsShareInputOutputAndResize(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	first := dialRecordingClient(t, url)
	second := dialRecordingClient(t, url)

	snapshot := createTestTerminal(t, first)
	terminalID := snapshot.Terminal.TerminalID
	second.mustAttachTerminal(t, terminalID, 80, 24)

	// Both attached clients may write, and each sees the resulting shared
	// stream from the one PTY.
	first.writeTerminal(t, terminalID, "printf 'FIRST-%d\\n' $((9*9))\n")
	first.waitForOutput(t, "FIRST-81")
	second.waitForOutput(t, "FIRST-81")

	second.writeTerminal(t, terminalID, "printf 'SECOND-%d\\n' $((9*9))\n")
	first.waitForOutput(t, "SECOND-81")
	second.waitForOutput(t, "SECOND-81")

	// Once the second view is focused, its resize applies.
	second.notify(t, wire.MethodTerminalFocus, wire.TerminalIDParams{TerminalID: terminalID})
	second.notify(t, wire.MethodTerminalResize, wire.TerminalResizeParams{TerminalID: terminalID, Columns: 96, Rows: 31, Appearance: testAppearance})
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		session, err := s.terminals.service.Get(terminalID)
		if err == nil {
			columns, rows := session.Size()
			if columns == 96 && rows == 31 {
				return
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("attached-client resize was not applied")
}

// One PTY has one size: the active view's. A view becomes active when it
// creates the terminal, is opened (focus) or is focused, which a view sends
// before what the user types; when it leaves, the view active before it takes
// over. Every client resizes at the same point in the output, from the
// resized stream item.
func TestTerminalSizeFollowsTheActiveView(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	laptop := dialRecordingClient(t, url)
	phone := dialRecordingClient(t, url)
	printSize := func(c *recordingClient, terminalID, label string) {
		c.writeTerminal(t, terminalID, "printf '"+label+"-%s\\n' \"$(stty size)\"\n")
	}
	attach := func(c *recordingClient, terminalID, attachmentID string, columns, rows uint16, focus bool) testView {
		var result wire.TerminalAttachResult
		c.call(t, wire.MethodTerminalAttach, wire.TerminalAttachParams{
			TerminalID: terminalID, Columns: columns, Rows: rows, AttachmentID: attachmentID,
			Appearance: testAppearance, Focus: focus,
		}, &result)
		return c.view(t, result)
	}

	var result wire.TerminalAttachResult
	laptop.call(t, wire.MethodTerminalCreate, wire.TerminalCreateParams{
		Cwd: t.TempDir(), Columns: 120, Rows: 40, AttachmentID: "laptop", Appearance: testAppearance,
	}, &result)
	created := laptop.view(t, result)
	terminalID := created.Terminal.TerminalID

	// A view reattaching keeps the laptop's grid, which its snapshot is at.
	reattached := attach(phone, terminalID, "phone-1", 41, 32, false)
	if reattached.Columns != 120 || reattached.Rows != 40 {
		t.Fatalf("phone reattach grid = %dx%d, want the laptop's 120x40", reattached.Columns, reattached.Rows)
	}
	// Input alone doesn't take the size: it may be a report the program
	// asked for, such as focus out when the phone locks.
	printSize(phone, terminalID, "INPUT")
	phone.waitForOutput(t, "INPUT-40 120")
	phone.notify(t, wire.MethodTerminalFocus, wire.TerminalIDParams{TerminalID: terminalID})
	printSize(phone, terminalID, "FOCUSED")
	phone.waitForOutput(t, "FOCUSED-32 41")

	// The laptop's window changing while the phone is active only records
	// the laptop's grid; focusing the laptop then takes it.
	laptop.notify(t, wire.MethodTerminalResize, wire.TerminalResizeParams{TerminalID: terminalID, Columns: 100, Rows: 30, Appearance: testAppearance})
	printSize(phone, terminalID, "STILL")
	still := reattached.stream.waitOutput(t, 0, "STILL-32 41")
	// Records arrive in order, so a resize to the laptop's grid would have
	// come before that output.
	if i := slices.IndexFunc(reattached.stream.snapshot()[:still], resizedTo(100, 30)); i >= 0 {
		t.Fatal("the laptop's resize applied while the phone was active")
	}
	laptop.notify(t, wire.MethodTerminalFocus, wire.TerminalIDParams{TerminalID: terminalID})
	reattached.stream.waitRecord(t, "resize to the laptop's grid", still, resizedTo(100, 30))
	seen, _ := created.stream.waitRecord(t, "resize to the laptop's grid", 0, resizedTo(100, 30))

	// Opening the terminal on the phone takes the size, and leaving gives it
	// back to the laptop, by detaching or by disconnecting.
	if opened := attach(phone, terminalID, "phone-2", 41, 20, true); opened.Columns != 41 || opened.Rows != 20 {
		t.Fatalf("phone open grid = %dx%d, want its own 41x20", opened.Columns, opened.Rows)
	}
	seen, _ = created.stream.waitRecord(t, "resize to the phone's grid", seen, resizedTo(41, 20))
	phone.notify(t, wire.MethodTerminalDetach, wire.TerminalDetachParams{TerminalID: terminalID, AttachmentID: "phone-2"})
	seen, _ = created.stream.waitRecord(t, "resize back to the laptop's grid", seen, resizedTo(100, 30))

	attach(phone, terminalID, "phone-3", 41, 20, true)
	seen, _ = created.stream.waitRecord(t, "resize to the phone's grid", seen, resizedTo(41, 20))
	_ = phone.conn.Close()
	created.stream.waitRecord(t, "resize back to the laptop's grid", seen, resizedTo(100, 30))
}

func TestInvalidAttachDimensionsDoNotAffectExistingAttachment(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	first := dialRecordingClient(t, url)
	second := dialRecordingClient(t, url)

	snapshot := createTestTerminal(t, first)
	terminalID := snapshot.Terminal.TerminalID
	if _, err := second.attachTerminal(terminalID, 1, 24); err == nil {
		t.Fatal("attach with invalid dimensions succeeded")
	}
	first.writeTerminal(t, terminalID, "printf 'AFTER-BAD-ATTACH-%d\\n' $((4+3))\n")
	first.waitForOutput(t, "AFTER-BAD-ATTACH-7")
}

// TestTerminalDetachAndDisconnectKeepShellRunning covers both ways a client
// stops listening: neither may terminate the shell, and detached input must
// not reach the PTY.
func TestTerminalDetachAndDisconnectKeepShellRunning(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	client := dialRecordingClient(t, url)

	snapshot := createTestTerminal(t, client)
	terminalID := snapshot.Terminal.TerminalID
	client.writeTerminal(t, terminalID, "printf 'BEFORE-%d\\n' $((10+1))\n")
	client.waitForOutput(t, "BEFORE-11")

	client.notify(t, wire.MethodTerminalDetach, wire.TerminalDetachParams{TerminalID: terminalID})
	if code := snapshot.stream.waitClosed(t); code != websocket.StatusNormalClosure {
		t.Fatalf("detach closed the stream with %v, want %v", code, websocket.StatusNormalClosure)
	}
	client.writeTerminal(t, terminalID, "printf 'DETACHED-%d\\n' $((10+2))\n")

	reattach := client.mustAttachTerminal(t, terminalID, 80, 24)
	if !containsBytes(reattach.Snapshot, "BEFORE-11") {
		t.Fatal("snapshot lost pre-detach output")
	}
	if containsBytes(reattach.Snapshot, "DETACHED-12") {
		t.Fatal("input written while detached reached the PTY")
	}

	// A connection that closes takes its views and their streams with it;
	// its reconnect attaches again.
	_ = client.conn.Close()
	if code := reattach.stream.waitClosed(t); code != websocket.StatusGoingAway {
		t.Fatalf("disconnect closed the stream with %v, want %v", code, websocket.StatusGoingAway)
	}
	waitUntil(t, "the closed connection's view to go", func() bool {
		entry := s.terminals.entry(terminalID)
		entry.views.mu.Lock()
		defer entry.views.mu.Unlock()
		return len(entry.views.list) == 0
	})
	next := dialRecordingClient(t, url)
	if attach := next.mustAttachTerminal(t, terminalID, 80, 24); !containsBytes(attach.Snapshot, "BEFORE-11") {
		t.Fatal("client disconnect terminated the shell")
	}
}

// TestTerminalLateDetachKeepsReplacementAttachment reopens a terminal on the
// same connection while the closed view's detach is still on its way: the
// late detach names the old attachment and must not drop the new one's
// stream or input.
func TestTerminalLateDetachKeepsReplacementAttachment(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	client := newRecordingClient(t, s)

	created := createTestTerminal(t, client)
	terminalID := created.Terminal.TerminalID
	var result wire.TerminalAttachResult
	client.call(t, wire.MethodTerminalAttach, wire.TerminalAttachParams{TerminalID: terminalID, Columns: 80, Rows: 24, AttachmentID: "view-2", Appearance: testAppearance}, &result)
	reopened := client.view(t, result)
	// The replaced view's stream ended when the new view's ticket was issued.
	if code := created.stream.waitClosed(t); code != websocket.StatusNormalClosure {
		t.Fatalf("replaced view's stream closed with %v, want %v", code, websocket.StatusNormalClosure)
	}
	client.notify(t, wire.MethodTerminalDetach, wire.TerminalDetachParams{TerminalID: terminalID})

	client.writeTerminal(t, terminalID, "printf 'REOPENED-%d\\n' $((30+3))\n")
	reopened.stream.waitOutput(t, 1, "REOPENED-33")
}

// A shell that ends by itself, as with exit or Ctrl-D, takes its terminal with
// it, for every client and across a restart, whether or not anyone has it open.
func TestTerminalShellExitRemovesTheTerminal(t *testing.T) {
	useQuietTestShell(t)
	dir := t.TempDir()
	s := newTestServerAt(t, dir)
	url := newWSTestServer(t, s)
	client := dialRecordingClient(t, url)
	observer := dialRecordingClient(t, url)
	subscribeTerminalListSnapshot(t, observer)

	removed := func(terminalID string) {
		t.Helper()
		waitForListItem(t, observer, "removal", func(item wire.TerminalListStreamItem) bool {
			return item.Kind == wire.TerminalListItemRemoved && item.TerminalID == terminalID
		})
		if _, err := client.attachTerminal(terminalID, 80, 24); err == nil {
			t.Fatal("attached to a terminal whose shell exited")
		}
	}

	opened := createTestTerminal(t, client)
	client.writeTerminal(t, opened.Terminal.TerminalID, "exit 4\n")
	if code := opened.stream.waitClosed(t); code != websocket.StatusNormalClosure {
		t.Fatalf("exit closed the stream with %v, want %v", code, websocket.StatusNormalClosure)
	}
	removed(opened.Terminal.TerminalID)

	// Input needs an attached view, so this shell is told to exit before the
	// view leaves.
	background := createTestTerminal(t, client)
	client.writeTerminal(t, background.Terminal.TerminalID, "sleep 1; exit\n")
	client.notify(t, wire.MethodTerminalDetach, wire.TerminalDetachParams{TerminalID: background.Terminal.TerminalID})
	removed(background.Terminal.TerminalID)

	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	restarted := dialRecordingClient(t, newWSTestServer(t, newTestServerAt(t, dir)))
	if rows := subscribeTerminalListSnapshot(t, restarted).Terminals; len(rows) != 0 {
		t.Fatalf("after restart the list has %d terminals, want none", len(rows))
	}
}

func containsBytes(data []byte, marker string) bool {
	return bytes.Contains(data, []byte(marker))
}

// TestTerminalInputToProgramNotReadingDoesNotBlockConnection pastes more than
// the PTY buffer holds into a program that never reads stdin. The input must
// not stall the connection: a later delete still completes promptly.
func TestTerminalInputToProgramNotReadingDoesNotBlockConnection(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	client := newRecordingClient(t, s)

	created := createTestTerminal(t, client)
	terminalID := created.Terminal.TerminalID
	client.writeTerminal(t, terminalID, "printf 'SLEEPING-%d\\n' $((5+5)); exec sleep 600\n")
	client.waitForOutput(t, "SLEEPING-10")
	paste := strings.Repeat(strings.Repeat("x", 63)+"\n", 16)
	for range 256 {
		client.writeTerminal(t, terminalID, paste)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := client.conn.Call(ctx, wire.MethodTerminalDelete, wire.TerminalIDParams{TerminalID: terminalID}).Await(ctx, nil); err != nil {
		t.Fatalf("terminal.delete behind unread input: %v", err)
	}
}

// A program can exit while a view resizes its terminal: the run's exit and
// the resize each wait for what the other holds unless they're ordered.
func TestTerminalExitDuringResizesFinishes(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	client := dialRecordingClient(t, url)
	for range 20 {
		created := createTestTerminal(t, client)
		terminalID := created.Terminal.TerminalID
		stop := make(chan struct{})
		resized := make(chan struct{})
		go func() {
			defer close(resized)
			for columns := uint16(0); ; columns++ {
				select {
				case <-stop:
					return
				default:
				}
				ctx, cancel := context.WithTimeout(context.Background(), time.Second)
				_ = client.conn.Notify(ctx, wire.MethodTerminalResize, wire.TerminalResizeParams{
					TerminalID: terminalID, Columns: 80 + columns%2, Rows: 24, Appearance: testAppearance,
				})
				cancel()
			}
		}()
		client.writeTerminal(t, terminalID, "exit\n")
		created.stream.waitClosed(t)
		close(stop)
		<-resized
	}
}
