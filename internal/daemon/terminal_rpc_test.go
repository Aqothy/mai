package daemon

// End-to-end terminal RPC tests use a real WebSocket client the way the Swift
// app does: create attaches the caller, write/resize arrive as notifications,
// and the view's terminal stream carries the terminal back.

import (
	"bytes"
	"fmt"
	"slices"
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
	return bytes.Contains(c.terminalOutput.Bytes(), []byte(marker))
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

func createTestTerminal(t *testing.T, c *recordingClient) testView {
	t.Helper()
	var result wire.TerminalAttachResult
	c.call(t, wire.MethodTerminalCreate, wire.TerminalCreateParams{
		Cwd:        t.TempDir(),
		Columns:    80,
		Rows:       24,
		Appearance: testAppearance,
	}, &result)
	return c.view(t, result)
}

// testAppearance is a dark view's theme: Ghostty's default colors.
var testAppearance = wire.TerminalAppearance{
	ColorScheme: terminal.ColorSchemeDark,
	Foreground:  "#ffffff",
	Background:  "#282c34",
}

func (c *recordingClient) writeTerminal(t *testing.T, terminalID, data string) {
	t.Helper()
	c.notify(t, wire.MethodTerminalWrite, wire.TerminalWriteParams{TerminalID: terminalID, Data: []byte(data)})
}

func (c *recordingClient) attachTerminal(terminalID string, columns, rows uint16) (wire.TerminalAttachResult, error) {
	var result wire.TerminalAttachResult
	err := c.callErr(wire.MethodTerminalAttach, wire.TerminalAttachParams{TerminalID: terminalID, Columns: columns, Rows: rows, Appearance: testAppearance}, &result)
	return result, err
}

func (c *recordingClient) mustAttachTerminal(t *testing.T, terminalID string, columns, rows uint16) testView {
	t.Helper()
	result, err := c.attachTerminal(terminalID, columns, rows)
	if err != nil {
		t.Fatalf("attach %s: %v", terminalID, err)
	}
	return c.view(t, result)
}

func TestTerminalCreateWriteResizeRoundTrip(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	client := newRecordingClient(t, s)

	snapshot := createTestTerminal(t, client)
	terminalID := snapshot.Terminal.TerminalID
	if terminalID == "" {
		t.Fatalf("snapshot missing identity: %+v", snapshot)
	}

	client.writeTerminal(t, terminalID, "printf 'RPC-%d\\n' $((40+2))\n")
	client.waitForOutput(t, "RPC-42")

	client.notify(t, wire.MethodTerminalResize, wire.TerminalResizeParams{TerminalID: terminalID, Columns: 111, Rows: 31, Appearance: testAppearance})
	client.writeTerminal(t, terminalID, "printf 'SIZE-%s-END\\n' \"$(stty size | tr ' ' 'x')\"\n")
	client.waitForOutput(t, "SIZE-31x111-END")
}

func TestTerminalLargeOutputRemainsConnected(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	client := newRecordingClient(t, s)

	snapshot := createTestTerminal(t, client)
	terminalID := snapshot.Terminal.TerminalID
	const outputBytes = 5 * 1024 * 1024
	client.writeTerminal(t, terminalID, fmt.Sprintf("head -c %d /dev/zero; printf '\\nLARGE-OUTPUT-DONE\\n'\n", outputBytes))
	client.waitForOutputLength(t, outputBytes)
	client.waitForOutput(t, "LARGE-OUTPUT-DONE")

	// A subsequent command proves the same stream remains live after the
	// output burst, and the burst came through whole, without a resync.
	client.writeTerminal(t, terminalID, "printf 'AFTER-LARGE-OUTPUT\\n'\n")
	client.waitForOutput(t, "AFTER-LARGE-OUTPUT")
	records := snapshot.stream.snapshot()
	if slices.IndexFunc(records[1:], isSnapshot) >= 0 {
		t.Fatal("a reading view was resynced")
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
	terminalID := snapshot.Terminal.TerminalID

	intruder.writeTerminal(t, terminalID, "printf 'INTRUDER-%d\\n' $((7*3))\n")
	controller.writeTerminal(t, terminalID, "printf 'OWNER-%d\\n' $((7*3))\n")
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

// A program reading a line lets the user erase what they typed: Backspace
// after "é" removes the whole character, not one of its two bytes.
func TestTerminalLineInputErasesWholeCharacters(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	client := newRecordingClient(t, s)
	created := createTestTerminal(t, client)
	terminalID := created.Terminal.TerminalID

	client.writeTerminal(t, terminalID, "read line; printf 'LINE[%s]%s\\n' \"$line\" END\n")
	client.writeTerminal(t, terminalID, "aé\x7f\n")
	client.waitForOutput(t, "]END")
	if !client.outputContains("LINE[a]END") {
		t.Fatal("erasing after é left part of it in the line")
	}
}
