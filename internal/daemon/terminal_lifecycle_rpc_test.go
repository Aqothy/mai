package daemon

// Increment 4 lifecycle tests: reattach snapshot ordering, detach without
// termination, relaunch run fencing, and shared multi-client attachment, all
// through real WebSocket clients.

import (
	"bytes"
	"context"
	"testing"
	"time"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/terminal"
)

func attachTestTerminal(t *testing.T, c *terminalTestClient, terminalID string) wire.TerminalAttachSnapshot {
	t.Helper()
	var snapshot wire.TerminalAttachSnapshot
	c.call(t, RPCMethodTerminalAttach, wire.TerminalAttachParams{
		TerminalID: terminalID,
		Columns:    80,
		Rows:       24,
	}, &snapshot)
	return snapshot
}

func (c *terminalTestClient) itemsAbove(sequence uint64) []wire.TerminalStreamItem {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []wire.TerminalStreamItem
	for _, item := range c.items {
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
	first := dialTerminalClient(t, url)

	snapshot := createTestTerminal(t, first)
	terminalID := snapshot.Terminal.TerminalID
	first.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'HISTORY-%d\\n' $((80+8))\n"),
	})
	first.waitForOutput(t, "HISTORY-88")

	second := dialTerminalClient(t, url)
	attach := attachTestTerminal(t, second, terminalID)
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
	second.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
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

func TestTerminalAttachSnapshotReportsAppliedGrid(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	first := dialTerminalClient(t, url)
	second := dialTerminalClient(t, url)

	created := createTestTerminal(t, first)
	var attached wire.TerminalAttachSnapshot
	second.call(t, RPCMethodTerminalAttach, wire.TerminalAttachParams{
		TerminalID: created.Terminal.TerminalID,
		Columns:    96,
		Rows:       31,
	}, &attached)

	if attached.Columns != 96 || attached.Rows != 31 {
		t.Fatalf("attach grid = %dx%d, want 96x31", attached.Columns, attached.Rows)
	}
}

func TestTerminalMultipleAttachedClientsShareInputOutputAndResize(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	first := dialTerminalClient(t, url)
	second := dialTerminalClient(t, url)

	snapshot := createTestTerminal(t, first)
	terminalID := snapshot.Terminal.TerminalID
	attach := attachTestTerminal(t, second, terminalID)

	// Both attached clients may write, and each sees the resulting shared
	// stream from the one PTY.
	first.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'FIRST-%d\\n' $((9*9))\n"),
	})
	first.waitForOutput(t, "FIRST-81")
	second.waitForOutput(t, "FIRST-81")

	second.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      attach.RunID,
		Data:       []byte("printf 'SECOND-%d\\n' $((9*9))\n"),
	})
	first.waitForOutput(t, "SECOND-81")
	second.waitForOutput(t, "SECOND-81")

	// Resizes are shared PTY state; the latest valid resize wins.
	first.notify(t, RPCMethodTerminalResize, wire.TerminalResizeParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Columns:    120,
		Rows:       40,
	})
	deadline := time.Now().Add(15 * time.Second)
	firstResizeApplied := false
	for time.Now().Before(deadline) {
		session, err := s.terminals.service.Get(terminalID)
		if err == nil {
			columns, rows := session.Size()
			if columns == 120 && rows == 40 {
				firstResizeApplied = true
				break
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !firstResizeApplied {
		t.Fatal("first attached-client resize was not applied")
	}
	second.notify(t, RPCMethodTerminalResize, wire.TerminalResizeParams{
		TerminalID: terminalID,
		RunID:      attach.RunID,
		Columns:    96,
		Rows:       31,
	})
	deadline = time.Now().Add(15 * time.Second)
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
	t.Fatal("latest attached-client resize was not applied")
}

func TestInvalidAttachDimensionsDoNotAffectExistingAttachmentOrRelaunch(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	first := dialTerminalClient(t, url)
	second := dialTerminalClient(t, url)

	snapshot := createTestTerminal(t, first)
	terminalID := snapshot.Terminal.TerminalID
	ctx, cancel := timeout15()
	defer cancel()
	var invalidAttach wire.TerminalAttachSnapshot
	if err := second.conn.Call(ctx, RPCMethodTerminalAttach, wire.TerminalAttachParams{
		TerminalID: terminalID,
		Columns:    1,
		Rows:       24,
	}).Await(ctx, &invalidAttach); err == nil {
		t.Fatal("attach with invalid dimensions succeeded")
	}

	first.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'AFTER-BAD-ATTACH-%d\\n' $((4+3))\n"),
	})
	first.waitForOutput(t, "AFTER-BAD-ATTACH-7")

	var invalidRelaunch wire.TerminalAttachSnapshot
	if err := second.conn.Call(ctx, RPCMethodTerminalRelaunch, wire.TerminalAttachParams{
		TerminalID: terminalID,
		Columns:    80,
		Rows:       301,
	}).Await(ctx, &invalidRelaunch); err == nil {
		t.Fatal("relaunch with invalid dimensions succeeded")
	}

	first.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
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
	client := dialTerminalClient(t, url)

	snapshot := createTestTerminal(t, client)
	terminalID := snapshot.Terminal.TerminalID
	client.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'BEFORE-%d\\n' $((10+1))\n"),
	})
	client.waitForOutput(t, "BEFORE-11")

	client.notify(t, RPCMethodTerminalDetach, wire.TerminalDetachParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
	})

	// Detached input must be ignored, and the shell must stay alive.
	client.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
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
	first := dialTerminalClient(t, url)

	snapshot := createTestTerminal(t, first)
	terminalID := snapshot.Terminal.TerminalID
	first.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'SURVIVES-%d\\n' $((30+3))\n"),
	})
	first.waitForOutput(t, "SURVIVES-33")
	_ = first.conn.Close()

	second := dialTerminalClient(t, url)
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
	client := dialTerminalClient(t, url)

	snapshot := createTestTerminal(t, client)
	terminalID := snapshot.Terminal.TerminalID
	client.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'OLDRUN-%d\\n' $((20+2))\n"),
	})
	client.waitForOutput(t, "OLDRUN-22")

	var relaunched wire.TerminalAttachSnapshot
	client.call(t, RPCMethodTerminalRelaunch, wire.TerminalAttachParams{
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
	client.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'STALERUN-%d\\n' $((40+4))\n"),
	})
	client.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
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
	client := dialTerminalClient(t, url)

	snapshot := createTestTerminal(t, client)
	terminalID := snapshot.Terminal.TerminalID
	client.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: terminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'FINAL-%d\\n' $((90+9)); exit 4\n"),
	})

	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if statuses := client.statusItems(); len(statuses) > 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	other := dialTerminalClient(t, url)
	attach := attachTestTerminal(t, other, terminalID)
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

func timeout15() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 15*time.Second)
}

func attachOnce(c *terminalTestClient, terminalID string) (wire.TerminalAttachSnapshot, error) {
	var snapshot wire.TerminalAttachSnapshot
	ctx, cancel := timeout15()
	defer cancel()
	err := c.conn.Call(ctx, RPCMethodTerminalAttach, wire.TerminalAttachParams{
		TerminalID: terminalID,
		Columns:    80,
		Rows:       24,
	}).Await(ctx, &snapshot)
	return snapshot, err
}

func containsBytes(data []byte, marker string) bool {
	return bytes.Contains(data, []byte(marker))
}
