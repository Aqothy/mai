package daemon

// Terminal lifecycle tests: reattach snapshot ordering, detach without
// termination, relaunch run fencing, and shared multi-client attachment, all
// through real WebSocket clients.

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/terminal"
)

func (c *recordingClient) outputItems() []wire.TerminalStreamItem {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]wire.TerminalStreamItem(nil), c.terminalItems...)
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

	// The new listener can write; live output arrives above the snapshot
	// sequence in order.
	second.writeTerminal(t, terminalID, attach.RunID, "printf 'LIVE-%d\\n' $((60+6))\n")
	second.waitForOutput(t, "LIVE-66")
	for _, item := range second.outputItems() {
		if item.Kind == terminal.StreamItemOutput && item.Sequence <= attach.Sequence {
			t.Fatalf("live output sequence %d not above snapshot %d", item.Sequence, attach.Sequence)
		}
	}
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
	attach := func(c *recordingClient, terminalID, attachmentID string, columns, rows uint16, focus bool) wire.TerminalAttachSnapshot {
		var snapshot wire.TerminalAttachSnapshot
		c.call(t, wire.MethodTerminalAttach, wire.TerminalAttachParams{
			TerminalID: terminalID, Columns: columns, Rows: rows, AttachmentID: attachmentID,
			Appearance: testAppearance, Focus: focus,
		}, &snapshot)
		return snapshot
	}
	resizedAfter := func(c *recordingClient, after uint64, columns, rows uint16) uint64 {
		return c.waitForStreamItem(t, func(item wire.TerminalStreamItem) bool {
			return item.Kind == terminal.StreamItemResized && item.Sequence > after && item.Columns == columns && item.Rows == rows
		}).Sequence
	}

	var created wire.TerminalAttachSnapshot
	laptop.call(t, wire.MethodTerminalCreate, wire.TerminalCreateParams{
		Cwd: t.TempDir(), Columns: 120, Rows: 40, AttachmentID: "laptop", Appearance: testAppearance,
	}, &created)
	terminalID, runID := created.Terminal.TerminalID, created.RunID

	// A view reattaching keeps the laptop's grid, which its snapshot is at.
	if snapshot := attach(phone, terminalID, "phone-1", 41, 32, false); snapshot.Columns != 120 || snapshot.Rows != 40 {
		t.Fatalf("phone reattach grid = %dx%d, want the laptop's 120x40", snapshot.Columns, snapshot.Rows)
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
	phone.waitForOutput(t, "STILL-32 41")
	// Items arrive in sequence order, so a resize to the laptop's grid would
	// have come before that output.
	for _, item := range phone.outputItems() {
		if item.Kind == terminal.StreamItemResized && item.Columns == 100 {
			t.Fatalf("the laptop's resize applied while the phone was active: %+v", item)
		}
	}
	laptop.notify(t, wire.MethodTerminalFocus, wire.TerminalIDParams{TerminalID: terminalID})
	seq := resizedAfter(phone, 0, 100, 30)

	// Opening the terminal on the phone takes the size, and leaving gives it
	// back to the laptop, by detaching or by disconnecting.
	if snapshot := attach(phone, terminalID, "phone-2", 41, 20, true); snapshot.Columns != 41 || snapshot.Rows != 20 {
		t.Fatalf("phone open grid = %dx%d, want its own 41x20", snapshot.Columns, snapshot.Rows)
	}
	seq = resizedAfter(laptop, seq, 41, 20)
	phone.notify(t, wire.MethodTerminalDetach, wire.TerminalDetachParams{TerminalID: terminalID, AttachmentID: "phone-2"})
	seq = resizedAfter(laptop, seq, 100, 30)

	attach(phone, terminalID, "phone-3", 41, 20, true)
	seq = resizedAfter(laptop, seq, 41, 20)
	_ = phone.conn.Close()
	resizedAfter(laptop, seq, 100, 30)
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

	_ = client.conn.Close()
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
	var reopened wire.TerminalAttachSnapshot
	client.call(t, wire.MethodTerminalAttach, wire.TerminalAttachParams{TerminalID: terminalID, Columns: 80, Rows: 24, AttachmentID: "view-2", Appearance: testAppearance}, &reopened)
	client.notify(t, wire.MethodTerminalDetach, wire.TerminalDetachParams{TerminalID: terminalID})

	client.writeTerminal(t, terminalID, reopened.RunID, "printf 'REOPENED-%d\\n' $((30+3))\n")
	client.waitForOutput(t, "REOPENED-33")
}

func TestTerminalRelaunchFencesStaleRuns(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	client := newRecordingClient(t, s)

	snapshot := createTestTerminal(t, client)
	terminalID := snapshot.Terminal.TerminalID
	client.writeTerminal(t, terminalID, snapshot.RunID, "printf 'OLDRUN-%d\\n' $((20+2))\n")
	client.waitForOutput(t, "OLDRUN-22")

	var relaunched wire.TerminalAttachSnapshot
	client.call(t, wire.MethodTerminalRelaunch, wire.TerminalRelaunchParams{TerminalID: terminalID, Columns: 80, Rows: 24, Appearance: testAppearance}, &relaunched)
	if relaunched.RunID == snapshot.RunID {
		t.Fatal("relaunch reused the old run id")
	}
	if containsBytes(relaunched.Snapshot, "OLDRUN-22") {
		t.Fatal("relaunch kept the old run's snapshot")
	}

	// Stale input carrying the old run id cannot reach the new shell.
	client.writeTerminal(t, terminalID, snapshot.RunID, "printf 'STALERUN-%d\\n' $((40+4))\n")
	client.writeTerminal(t, terminalID, relaunched.RunID, "printf 'FRESH-%d\\n' $((40+5))\n")
	client.waitForOutput(t, "FRESH-45")
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
	status := client.waitForStatus(t)
	if status.Status != terminal.StatusExited || status.ExitCode == nil || *status.ExitCode != 4 {
		t.Fatalf("streamed status = %s exit %v, want exited 4", status.Status, status.ExitCode)
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
		exited := make(chan struct{})
		go func() {
			defer close(exited)
			for {
				for _, item := range client.outputItems() {
					if item.TerminalID == terminalID && item.Kind == terminal.StreamItemStatus {
						return
					}
				}
				time.Sleep(10 * time.Millisecond)
			}
		}()
		select {
		case <-exited:
		case <-time.After(10 * time.Second):
			t.Fatalf("round %d: the run never reported its exit", round)
		}
		close(stop)
		<-resized
	}
}
