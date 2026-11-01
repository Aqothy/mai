package daemon

// Terminal lifecycle tests: reattach snapshot ordering, detach without
// termination, relaunch run fencing, and shared multi-client attachment, all
// through real WebSocket clients.

import (
	"bytes"
	"context"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/terminal"
)

func isExited(record testRecord) bool { return record.kind == wire.TerminalRecordExited }

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
	first.writeTerminal(t, terminalID, snapshot.RunID, "printf 'HISTORY-%d\\n' $((80+8))\n")
	first.waitForOutput(t, "HISTORY-88")

	second := dialRecordingClient(t, url)
	attach := second.mustAttachTerminal(t, terminalID, 96, 31)
	if attach.RunID != snapshot.RunID {
		t.Fatalf("attach run id = %s, want %s", attach.RunID, snapshot.RunID)
	}
	// The Ghostty commit the daemon links.
	const wantFormat = "ghostty-gsn-v1-f54340ad77814fe319d136e5e915d6a48de8dd23"
	if attach.SnapshotFormat != wantFormat {
		t.Fatalf("snapshot format = %q, want %q", attach.SnapshotFormat, wantFormat)
	}
	if !containsBytes(attach.Snapshot, "HISTORY-88") {
		t.Fatal("attach snapshot missing output produced before attach")
	}

	// The new listener can write, and its stream carries the output.
	second.writeTerminal(t, terminalID, attach.RunID, "printf 'LIVE-%d\\n' $((60+6))\n")
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
	attach := second.mustAttachTerminal(t, terminalID, 80, 24)

	// Both attached clients may write, and each sees the resulting shared
	// stream from the one PTY.
	first.writeTerminal(t, terminalID, snapshot.RunID, "printf 'FIRST-%d\\n' $((9*9))\n")
	first.waitForOutput(t, "FIRST-81")
	second.waitForOutput(t, "FIRST-81")

	second.writeTerminal(t, terminalID, attach.RunID, "printf 'SECOND-%d\\n' $((9*9))\n")
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
	printSize := func(c *recordingClient, terminalID, runID, label string) {
		c.writeTerminal(t, terminalID, runID, "printf '"+label+"-%s\\n' \"$(stty size)\"\n")
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
	terminalID, runID := created.Terminal.TerminalID, created.RunID

	// A view reattaching keeps the laptop's grid, which its snapshot is at.
	reattached := attach(phone, terminalID, "phone-1", 41, 32, false)
	if reattached.Columns != 120 || reattached.Rows != 40 {
		t.Fatalf("phone reattach grid = %dx%d, want the laptop's 120x40", reattached.Columns, reattached.Rows)
	}
	// Input alone doesn't take the size: it may be a report the program
	// asked for, such as focus out when the phone locks.
	printSize(phone, terminalID, runID, "INPUT")
	phone.waitForOutput(t, "INPUT-40 120")
	phone.notify(t, wire.MethodTerminalFocus, wire.TerminalIDParams{TerminalID: terminalID})
	printSize(phone, terminalID, runID, "FOCUSED")
	phone.waitForOutput(t, "FOCUSED-32 41")

	// The laptop's window changing while the phone is active only records
	// the laptop's grid; focusing the laptop then takes it.
	laptop.notify(t, wire.MethodTerminalResize, wire.TerminalResizeParams{TerminalID: terminalID, Columns: 100, Rows: 30, Appearance: testAppearance})
	printSize(phone, terminalID, runID, "STILL")
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

func TestInvalidAttachDimensionsDoNotAffectExistingAttachmentOrRelaunch(t *testing.T) {
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
	first.writeTerminal(t, terminalID, snapshot.RunID, "printf 'AFTER-BAD-ATTACH-%d\\n' $((4+3))\n")
	first.waitForOutput(t, "AFTER-BAD-ATTACH-7")

	if err := second.callErr(wire.MethodTerminalRelaunch, wire.TerminalRelaunchParams{TerminalID: terminalID, Columns: 80, Rows: 301, Appearance: testAppearance}, nil); err == nil {
		t.Fatal("relaunch with invalid dimensions succeeded")
	}
	first.writeTerminal(t, terminalID, snapshot.RunID, "printf 'AFTER-BAD-RELAUNCH-%d\\n' $((4+4))\n")
	first.waitForOutput(t, "AFTER-BAD-RELAUNCH-8")
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
	client.writeTerminal(t, terminalID, snapshot.RunID, "printf 'BEFORE-%d\\n' $((10+1))\n")
	client.waitForOutput(t, "BEFORE-11")

	client.notify(t, wire.MethodTerminalDetach, wire.TerminalDetachParams{TerminalID: terminalID})
	if code := snapshot.stream.waitClosed(t); code != websocket.StatusNormalClosure {
		t.Fatalf("detach closed the stream with %v, want %v", code, websocket.StatusNormalClosure)
	}
	client.writeTerminal(t, terminalID, snapshot.RunID, "printf 'DETACHED-%d\\n' $((10+2))\n")

	reattach := client.mustAttachTerminal(t, terminalID, 80, 24)
	if reattach.RunID != snapshot.RunID {
		t.Fatal("detach terminated the shell")
	}
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
	if attach := next.mustAttachTerminal(t, terminalID, 80, 24); attach.RunID != snapshot.RunID {
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

	client.writeTerminal(t, terminalID, reopened.RunID, "printf 'REOPENED-%d\\n' $((30+3))\n")
	reopened.stream.waitOutput(t, 1, "REOPENED-33")
}

// Relaunching from one view gives that view a new stream on the new run,
// and moves every other view's open stream to the new run with a snapshot.
func TestTerminalRelaunchFencesStaleRuns(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	client := dialRecordingClient(t, url)
	other := dialRecordingClient(t, url)

	snapshot := createTestTerminal(t, client)
	terminalID := snapshot.Terminal.TerminalID
	watching := other.mustAttachTerminal(t, terminalID, 80, 24)
	client.writeTerminal(t, terminalID, snapshot.RunID, "printf 'OLDRUN-%d\\n' $((20+2))\n")
	watched := watching.stream.waitOutput(t, 1, "OLDRUN-22")

	var result wire.TerminalAttachResult
	client.call(t, wire.MethodTerminalRelaunch, wire.TerminalRelaunchParams{TerminalID: terminalID, Columns: 80, Rows: 24, Appearance: testAppearance}, &result)
	if code := snapshot.stream.waitClosed(t); code != websocket.StatusNormalClosure {
		t.Fatalf("relaunching view's old stream closed with %v, want %v", code, websocket.StatusNormalClosure)
	}
	relaunched := client.view(t, result)
	if relaunched.RunID == snapshot.RunID {
		t.Fatal("relaunch reused the old run id")
	}
	if containsBytes(relaunched.Snapshot, "OLDRUN-22") {
		t.Fatal("relaunch kept the old run's snapshot")
	}
	_, moved := watching.stream.waitRecord(t, "the other view's snapshot of the new run", watched, isSnapshot)
	if moved.snapshot.RunID != relaunched.RunID {
		t.Fatalf("other view moved to run %s, want %s", moved.snapshot.RunID, relaunched.RunID)
	}
	if containsBytes(moved.data, "OLDRUN-22") {
		t.Fatal("the other view's new snapshot kept the old run's output")
	}

	// Stale input carrying the old run id cannot reach the new shell.
	client.writeTerminal(t, terminalID, snapshot.RunID, "printf 'STALERUN-%d\\n' $((40+4))\n")
	client.writeTerminal(t, terminalID, relaunched.RunID, "printf 'FRESH-%d\\n' $((40+5))\n")
	relaunched.stream.waitOutput(t, 1, "FRESH-45")
	if client.outputContains("STALERUN-44") {
		t.Fatal("stale run input reached the relaunched shell")
	}
}

func TestTerminalAttachAfterNaturalExitShowsFinalState(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	client := dialRecordingClient(t, url)

	snapshot := createTestTerminal(t, client)
	terminalID := snapshot.Terminal.TerminalID
	client.writeTerminal(t, terminalID, snapshot.RunID, "printf 'FINAL-%d\\n' $((90+9)); exit 4\n")

	// The attached client sees the exit streamed with its code.
	_, exit := snapshot.stream.waitRecord(t, "the run's exit", 1, isExited)
	if exit.exited.Status != terminal.StatusExited || exit.exited.ExitCode == nil || *exit.exited.ExitCode != 4 {
		t.Fatalf("streamed exit = %s code %v, want exited 4", exit.exited.Status, exit.exited.ExitCode)
	}

	// A later client attaching at a different grid gets the retained final
	// screen at the run's last grid, which its view draws scaled.
	attach := dialRecordingClient(t, url).mustAttachTerminal(t, terminalID, 100, 30)
	if attach.Columns != 80 || attach.Rows != 24 {
		t.Fatalf("attach grid = %dx%d, want the run's last 80x24", attach.Columns, attach.Rows)
	}
	if attach.Terminal.Status != terminal.StatusExited || attach.Terminal.ExitCode == nil || *attach.Terminal.ExitCode != 4 {
		t.Fatalf("attach status = %s exit %v, want exited 4", attach.Terminal.Status, attach.Terminal.ExitCode)
	}
	if !containsBytes(attach.Snapshot, "FINAL-99") {
		t.Fatal("attach after exit lost the final screen output")
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
	client.writeTerminal(t, terminalID, created.RunID, "printf 'SLEEPING-%d\\n' $((5+5)); exec sleep 600\n")
	client.waitForOutput(t, "SLEEPING-10")
	paste := strings.Repeat(strings.Repeat("x", 63)+"\n", 16)
	for range 256 {
		client.writeTerminal(t, terminalID, created.RunID, paste)
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
	for round := range 20 {
		created := createTestTerminal(t, client)
		terminalID, runID := created.Terminal.TerminalID, created.RunID
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
		client.writeTerminal(t, terminalID, runID, "exit\n")
		created.stream.waitRecord(t, fmt.Sprintf("round %d: the run's exit", round), 1, isExited)
		close(stop)
		<-resized
	}
}
