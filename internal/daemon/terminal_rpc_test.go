package daemon

// End-to-end terminal RPC tests use a real WebSocket client the way the Swift
// app does: create attaches the caller, write/resize arrive as notifications,
// and terminal.subscribe items stream back ordered by sequence.

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/terminal"
)

func (c *recordingClient) listItemsSnapshot() []wire.TerminalListStreamItem {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]wire.TerminalListStreamItem(nil), c.terminalListItems...)
}

func (c *recordingClient) outputContains(marker string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return strings.Contains(c.terminalOutput.String(), marker)
}

func (c *recordingClient) waitForOutput(t *testing.T, marker string) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if c.outputContains(marker) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for terminal output containing %q", marker)
}

func (c *recordingClient) outputLength() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.terminalOutput.Len()
}

func (c *recordingClient) largestOutputChunk() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	largest := 0
	for _, item := range c.terminalItems {
		if item.Kind == terminal.StreamItemOutput {
			largest = max(largest, len(item.Data))
		}
	}
	return largest
}

func (c *recordingClient) waitForOutputLength(t *testing.T, minimum int) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if c.outputLength() >= minimum {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %d terminal output bytes; received %d", minimum, c.outputLength())
}

// waitForStatus returns the first status item the terminal stream delivers.
func (c *recordingClient) waitForStatus(t *testing.T) wire.TerminalStreamItem {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		for _, item := range c.terminalItems {
			if item.Kind == terminal.StreamItemStatus {
				c.mu.Unlock()
				return item
			}
		}
		c.mu.Unlock()
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("timed out waiting for terminal status stream item")
	return wire.TerminalStreamItem{}
}

func createTestTerminal(t *testing.T, c *recordingClient) wire.TerminalAttachSnapshot {
	t.Helper()
	var snapshot wire.TerminalAttachSnapshot
	c.call(t, wire.MethodTerminalCreate, wire.TerminalCreateParams{
		Cwd:     t.TempDir(),
		Columns: 80,
		Rows:    24,
	}, &snapshot)
	return snapshot
}

func (c *recordingClient) writeTerminal(t *testing.T, terminalID, runID, data string) {
	t.Helper()
	c.notify(t, wire.MethodTerminalWrite, wire.TerminalWriteParams{TerminalID: terminalID, RunID: runID, Data: []byte(data)})
}

func (c *recordingClient) attachTerminal(terminalID string, columns, rows uint16) (wire.TerminalAttachSnapshot, error) {
	var snapshot wire.TerminalAttachSnapshot
	err := c.callErr(wire.MethodTerminalAttach, wire.TerminalAttachParams{TerminalID: terminalID, Columns: columns, Rows: rows}, &snapshot)
	return snapshot, err
}

func (c *recordingClient) mustAttachTerminal(t *testing.T, terminalID string, columns, rows uint16) wire.TerminalAttachSnapshot {
	t.Helper()
	snapshot, err := c.attachTerminal(terminalID, columns, rows)
	if err != nil {
		t.Fatalf("attach %s: %v", terminalID, err)
	}
	return snapshot
}

func TestTerminalCreateWriteResizeRoundTrip(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	client := newRecordingClient(t, s)

	snapshot := createTestTerminal(t, client)
	terminalID, runID := snapshot.Terminal.TerminalID, snapshot.RunID
	if terminalID == "" || runID == "" {
		t.Fatalf("snapshot missing identity: %+v", snapshot)
	}
	if snapshot.Terminal.Status != terminal.StatusRunning {
		t.Fatalf("status = %s, want running", snapshot.Terminal.Status)
	}

	client.writeTerminal(t, terminalID, runID, "printf 'RPC-%d\\n' $((40+2))\n")
	client.waitForOutput(t, "RPC-42")

	client.notify(t, wire.MethodTerminalResize, wire.TerminalResizeParams{TerminalID: terminalID, RunID: runID, Columns: 111, Rows: 31})
	client.writeTerminal(t, terminalID, runID, "printf 'SIZE-%s-END\\n' \"$(stty size | tr ' ' 'x')\"\n")
	client.waitForOutput(t, "SIZE-31x111-END")
}

func TestTerminalLargeOutputRemainsConnected(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	client := newRecordingClient(t, s)

	snapshot := createTestTerminal(t, client)
	terminalID, runID := snapshot.Terminal.TerminalID, snapshot.RunID
	const outputBytes = 5 * 1024 * 1024
	const maximumNotificationBytes = 64 * 1024
	client.writeTerminal(t, terminalID, runID, fmt.Sprintf("head -c %d /dev/zero; printf '\\nLARGE-OUTPUT-DONE\\n'\n", outputBytes))
	client.waitForOutputLength(t, outputBytes)
	client.waitForOutput(t, "LARGE-OUTPUT-DONE")
	if largest := client.largestOutputChunk(); largest > maximumNotificationBytes {
		t.Fatalf("largest terminal notification was %d bytes, want at most %d", largest, maximumNotificationBytes)
	}

	// A subsequent command proves the same attached connection remains live
	// after the output burst instead of being overflow-closed.
	client.writeTerminal(t, terminalID, runID, "printf 'AFTER-LARGE-OUTPUT\\n'\n")
	client.waitForOutput(t, "AFTER-LARGE-OUTPUT")

	client.mu.Lock()
	defer client.mu.Unlock()
	var last uint64
	for _, item := range client.terminalItems {
		if item.Kind != terminal.StreamItemOutput {
			continue
		}
		if last != 0 && item.Sequence != last+1 {
			t.Fatalf("terminal output sequence jumped from %d to %d", last, item.Sequence)
		}
		last = item.Sequence
	}
}

func TestTerminalWriteFromUnattachedClientIsIgnored(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	controller := dialRecordingClient(t, url)
	intruder := dialRecordingClient(t, url)

	snapshot := createTestTerminal(t, controller)
	terminalID, runID := snapshot.Terminal.TerminalID, snapshot.RunID

	intruder.writeTerminal(t, terminalID, runID, "printf 'INTRUDER-%d\\n' $((7*3))\n")
	controller.writeTerminal(t, terminalID, runID, "printf 'OWNER-%d\\n' $((7*3))\n")
	controller.waitForOutput(t, "OWNER-21")

	if controller.outputContains("INTRUDER-21") {
		t.Fatal("unattached client input reached the PTY")
	}
	if intruder.outputContains("OWNER-21") {
		t.Fatal("terminal output streamed to a client that never attached")
	}
}

// useQuietTestShell keeps login-shell startup deterministic for daemon tests.
func useQuietTestShell(t *testing.T) {
	t.Helper()
	t.Setenv("SHELL", "/bin/zsh")
	t.Setenv("ZDOTDIR", t.TempDir())
}
