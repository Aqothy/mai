package daemon

// Terminal lifecycle tests: reattach snapshot ordering, detach without
// termination, relaunch run fencing, and shared multi-client attachment, all
// through real WebSocket clients.

import (
	"bytes"
	"testing"
	"time"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/terminal"
)

func attachTestTerminal(t *testing.T, c *recordingClient, terminalID string) wire.TerminalAttachSnapshot {
	t.Helper()
	var snapshot wire.TerminalAttachSnapshot
	c.call(t, wire.MethodTerminalAttach, wire.TerminalAttachParams{
		TerminalID: terminalID,
		Columns:    80,
		Rows:       24,
	}, &snapshot)
	return snapshot
}

func (c *recordingClient) itemsAbove(sequence uint64) []wire.TerminalStreamItem {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []wire.TerminalStreamItem
	for _, item := range c.terminalItems {
		if item.Sequence > sequence {
			out = append(out, item)
		}
	}
	return out
}

func TestTerminalReattachReceivesSnapshotThenLive(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	first := dialRecordingClient(t, url)

	snapshot := createTestTerminal(t, first)
	terminalID := snapshot.Terminal.TerminalID
	first.notify(t, wire.MethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'HISTORY-%d\\n' $((80+8))\n"),
	})
	first.waitForOutput(t, "HISTORY-88")

	// The attach snapshot reports the grid the attaching client asked for.
	second := dialRecordingClient(t, url)
	var attach wire.TerminalAttachSnapshot
	second.call(t, wire.MethodTerminalAttach, wire.TerminalAttachParams{
		TerminalID: terminalID,
		Columns:    96,
		Rows:       31,
	}, &attach)
	if attach.Columns != 96 || attach.Rows != 31 {
		t.Fatalf("attach grid = %dx%d, want 96x31", attach.Columns, attach.Rows)
	}
	if attach.RunID != snapshot.RunID {
		t.Fatalf("attach run id = %s, want %s", attach.RunID, snapshot.RunID)
	}
	if attach.SnapshotFormat != terminal.GhosttySnapshotFormat {
		t.Fatalf("snapshot format = %q, want %q", attach.SnapshotFormat, terminal.GhosttySnapshotFormat)
	}
	if !containsBytes(attach.Snapshot, "HISTORY-88") {
		t.Fatal("attach snapshot missing output produced before attach")
	}

	// The new listener can write; live output arrives above the snapshot
	// sequence in order.
	second.notify(t, wire.MethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      attach.RunID,
		Data:       []byte("printf 'LIVE-%d\\n' $((60+6))\n"),
	})
	second.waitForOutput(t, "LIVE-66")
	for _, item := range second.itemsAbove(0) {
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
	attach := attachTestTerminal(t, second, terminalID)

	// Both attached clients may write, and each sees the resulting shared
	// stream from the one PTY.
	first.notify(t, wire.MethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'FIRST-%d\\n' $((9*9))\n"),
	})
	first.waitForOutput(t, "FIRST-81")
	second.waitForOutput(t, "FIRST-81")

	second.notify(t, wire.MethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      attach.RunID,
		Data:       []byte("printf 'SECOND-%d\\n' $((9*9))\n"),
	})
	first.waitForOutput(t, "SECOND-81")
	second.waitForOutput(t, "SECOND-81")

	// Resizes are shared PTY state: an attached non-creator may resize too.
	second.notify(t, wire.MethodTerminalResize, wire.TerminalResizeParams{
		TerminalID: terminalID,
		RunID:      attach.RunID,
		Columns:    96,
		Rows:       31,
	})
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

func TestInvalidAttachDimensionsDoNotAffectExistingAttachmentOrRelaunch(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	first := dialRecordingClient(t, url)
	second := dialRecordingClient(t, url)

	snapshot := createTestTerminal(t, first)
	terminalID := snapshot.Terminal.TerminalID
	var invalidAttach wire.TerminalAttachSnapshot
	if err := second.callErr(wire.MethodTerminalAttach, wire.TerminalAttachParams{
		TerminalID: terminalID,
		Columns:    1,
		Rows:       24,
	}, &invalidAttach); err == nil {
		t.Fatal("attach with invalid dimensions succeeded")
	}

	first.notify(t, wire.MethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'AFTER-BAD-ATTACH-%d\\n' $((4+3))\n"),
	})
	first.waitForOutput(t, "AFTER-BAD-ATTACH-7")

	var invalidRelaunch wire.TerminalAttachSnapshot
	if err := second.callErr(wire.MethodTerminalRelaunch, wire.TerminalAttachParams{
		TerminalID: terminalID,
		Columns:    80,
		Rows:       301,
	}, &invalidRelaunch); err == nil {
		t.Fatal("relaunch with invalid dimensions succeeded")
	}

	first.notify(t, wire.MethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'AFTER-BAD-RELAUNCH-%d\\n' $((4+4))\n"),
	})
	first.waitForOutput(t, "AFTER-BAD-RELAUNCH-8")
}

func TestTerminalDetachKeepsShellRunning(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	client := dialRecordingClient(t, url)

	snapshot := createTestTerminal(t, client)
	terminalID := snapshot.Terminal.TerminalID
	client.notify(t, wire.MethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'BEFORE-%d\\n' $((10+1))\n"),
	})
	client.waitForOutput(t, "BEFORE-11")

	client.notify(t, wire.MethodTerminalDetach, wire.TerminalDetachParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
	})

	// Detached input must be ignored, and the shell must stay alive.
	client.notify(t, wire.MethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'DETACHED-%d\\n' $((10+2))\n"),
	})

	reattach := attachTestTerminal(t, client, terminalID)
	if reattach.RunID != snapshot.RunID {
		t.Fatal("detach terminated the shell")
	}
	if !containsBytes(reattach.Snapshot, "BEFORE-11") {
		t.Fatal("snapshot lost pre-detach output")
	}
	if containsBytes(reattach.Snapshot, "DETACHED-12") {
		t.Fatal("input written while detached reached the PTY")
	}
}

func TestTerminalDisconnectLeavesShellForNextClient(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	first := dialRecordingClient(t, url)

	snapshot := createTestTerminal(t, first)
	terminalID := snapshot.Terminal.TerminalID
	first.notify(t, wire.MethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'SURVIVES-%d\\n' $((30+3))\n"),
	})
	first.waitForOutput(t, "SURVIVES-33")
	_ = first.conn.Close()

	second := dialRecordingClient(t, url)
	deadline := time.Now().Add(15 * time.Second)
	var attach wire.TerminalAttachSnapshot
	for {
		var err error
		attach, err = attachOnce(second, terminalID)
		if err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("attach after disconnect: %v", err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if attach.RunID != snapshot.RunID {
		t.Fatal("client disconnect terminated the shell")
	}
	if !containsBytes(attach.Snapshot, "SURVIVES-33") {
		t.Fatal("snapshot lost output across client disconnect")
	}
}

func TestTerminalRelaunchFencesStaleRuns(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	client := dialRecordingClient(t, url)

	snapshot := createTestTerminal(t, client)
	terminalID := snapshot.Terminal.TerminalID
	client.notify(t, wire.MethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'OLDRUN-%d\\n' $((20+2))\n"),
	})
	client.waitForOutput(t, "OLDRUN-22")

	var relaunched wire.TerminalAttachSnapshot
	client.call(t, wire.MethodTerminalRelaunch, wire.TerminalAttachParams{
		TerminalID: terminalID,
		Columns:    80,
		Rows:       24,
	}, &relaunched)
	if relaunched.RunID == snapshot.RunID {
		t.Fatal("relaunch reused the old run id")
	}
	if containsBytes(relaunched.Snapshot, "OLDRUN-22") {
		t.Fatal("relaunch kept the old run's snapshot")
	}

	// Stale input carrying the old run id cannot reach the new shell.
	client.notify(t, wire.MethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'STALERUN-%d\\n' $((40+4))\n"),
	})
	client.notify(t, wire.MethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      relaunched.RunID,
		Data:       []byte("printf 'FRESH-%d\\n' $((40+5))\n"),
	})
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
	client.notify(t, wire.MethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'FINAL-%d\\n' $((90+9)); exit 4\n"),
	})

	// The attached client sees the exit streamed with its code.
	status := client.waitForStatus(t)
	if status.Status != terminal.StatusExited || status.ExitCode == nil || *status.ExitCode != 4 {
		t.Fatalf("streamed status = %s exit %v, want exited 4", status.Status, status.ExitCode)
	}

	// A later client attaching at a different grid gets the retained final
	// screen reflowed to its size.
	other := dialRecordingClient(t, url)
	var attach wire.TerminalAttachSnapshot
	other.call(t, wire.MethodTerminalAttach, wire.TerminalAttachParams{
		TerminalID: terminalID,
		Columns:    100,
		Rows:       30,
	}, &attach)
	if attach.Columns != 100 || attach.Rows != 30 {
		t.Fatalf("attach grid = %dx%d, want 100x30", attach.Columns, attach.Rows)
	}
	if attach.Terminal.Status != terminal.StatusExited {
		t.Fatalf("attach status = %s, want exited", attach.Terminal.Status)
	}
	if attach.Terminal.ExitCode == nil || *attach.Terminal.ExitCode != 4 {
		t.Fatalf("attach exit code = %v, want 4", attach.Terminal.ExitCode)
	}
	if !containsBytes(attach.Snapshot, "FINAL-99") {
		t.Fatal("attach after exit lost the final screen output")
	}
}

func attachOnce(c *recordingClient, terminalID string) (wire.TerminalAttachSnapshot, error) {
	var snapshot wire.TerminalAttachSnapshot
	err := c.callErr(wire.MethodTerminalAttach, wire.TerminalAttachParams{
		TerminalID: terminalID,
		Columns:    80,
		Rows:       24,
	}, &snapshot)
	return snapshot, err
}

func containsBytes(data []byte, marker string) bool {
	return bytes.Contains(data, []byte(marker))
}
