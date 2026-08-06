package daemon

// End-to-end terminal RPC tests use a real WebSocket client the way the Swift
// app does: create attaches the caller, write/resize arrive as notifications,
// and terminal.subscribe items stream back ordered by sequence.

import (
	"bytes"
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Aqothy/jsonrpc2"
	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/terminal"
	"github.com/coder/websocket"
)

// terminalTestClient records terminal.subscribe stream items in arrival order.
type terminalTestClient struct {
	conn *jsonrpc2.Connection

	mu     sync.Mutex
	items  []wire.TerminalStreamItem
	output bytes.Buffer
}

func dialTerminalClient(t *testing.T, url string) *terminalTestClient {
	t.Helper()
	c := &terminalTestClient{}
	ws, _, err := websocket.Dial(context.Background(), url, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	ws.SetReadLimit(-1)
	c.conn = jsonrpc2.NewWebSocketConnection(context.Background(), wsJSONRPC{conn: ws}, c)
	t.Cleanup(func() { _ = c.conn.Close() })
	return c
}

func (c *terminalTestClient) Handle(_ context.Context, req *jsonrpc2.Request) (any, error) {
	if req.IsCall() || req.Method != RPCMethodTerminalSubscribe {
		return nil, jsonrpc2.ErrNotHandled
	}
	var item wire.TerminalStreamItem
	if err := jsonUnmarshalParams(req, &item); err != nil {
		return nil, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.items = append(c.items, item)
	if item.Kind == terminal.StreamItemOutput {
		c.output.Write(item.Data)
	}
	return nil, nil
}

func jsonUnmarshalParams(req *jsonrpc2.Request, dst any) error {
	return decodeRPCParams(req, dst)
}

func (c *terminalTestClient) call(t *testing.T, method string, params any, result any) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := c.conn.Call(ctx, method, params).Await(ctx, result); err != nil {
		t.Fatalf("call %s: %v", method, err)
	}
}

func (c *terminalTestClient) notify(t *testing.T, method string, params any) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := c.conn.Notify(ctx, method, params); err != nil {
		t.Fatalf("notify %s: %v", method, err)
	}
}

func (c *terminalTestClient) outputContains(marker string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return strings.Contains(c.output.String(), marker)
}

func (c *terminalTestClient) waitForOutput(t *testing.T, marker string) {
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

func (c *terminalTestClient) outputLength() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.output.Len()
}

func (c *terminalTestClient) outputStats() (chunks, bytes int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, item := range c.items {
		if item.Kind != terminal.StreamItemOutput {
			continue
		}
		chunks++
		bytes += len(item.Data)
	}
	return chunks, bytes
}

func (c *terminalTestClient) waitForOutputLength(t *testing.T, minimum int) {
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

func (c *terminalTestClient) statusItems() []wire.TerminalStreamItem {
	c.mu.Lock()
	defer c.mu.Unlock()
	var statuses []wire.TerminalStreamItem
	for _, item := range c.items {
		if item.Kind == terminal.StreamItemStatus {
			statuses = append(statuses, item)
		}
	}
	return statuses
}

func createTestTerminal(t *testing.T, c *terminalTestClient) wire.TerminalAttachSnapshot {
	t.Helper()
	var snapshot wire.TerminalAttachSnapshot
	c.call(t, RPCMethodTerminalCreate, wire.TerminalCreateParams{
		Cwd:     t.TempDir(),
		Columns: 80,
		Rows:    24,
	}, &snapshot)
	return snapshot
}

func TestTerminalCreateWriteResizeRoundTrip(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	client := dialTerminalClient(t, url)

	snapshot := createTestTerminal(t, client)
	if snapshot.Terminal.TerminalID == "" || snapshot.RunID == "" {
		t.Fatalf("snapshot missing identity: %+v", snapshot)
	}
	if snapshot.Terminal.Status != terminal.StatusRunning {
		t.Fatalf("status = %s, want running", snapshot.Terminal.Status)
	}

	client.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: snapshot.Terminal.TerminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'RPC-%d\\n' $((40+2))\n"),
	})
	client.waitForOutput(t, "RPC-42")

	client.notify(t, RPCMethodTerminalResize, wire.TerminalResizeParams{
		TerminalID: snapshot.Terminal.TerminalID,
		RunID:      snapshot.RunID,
		Columns:    111,
		Rows:       31,
	})
	client.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: snapshot.Terminal.TerminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'SIZE-%s-END\\n' \"$(stty size | tr ' ' 'x')\"\n"),
	})
	client.waitForOutput(t, "SIZE-31x111-END")

	// Output sequences must be strictly increasing within the run.
	client.mu.Lock()
	var last uint64
	for _, item := range client.items {
		if item.Kind != terminal.StreamItemOutput {
			continue
		}
		if item.Sequence <= last {
			client.mu.Unlock()
			t.Fatalf("non-monotonic output sequence %d after %d", item.Sequence, last)
		}
		last = item.Sequence
	}
	client.mu.Unlock()
}

func TestTerminalLargeOutputRemainsConnected(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	client := dialTerminalClient(t, url)

	snapshot := createTestTerminal(t, client)
	const outputBytes = 5 * 1024 * 1024
	// Loose enough for scheduler variation, but strict enough to catch a
	// regression to publishing nearly every small PTY read independently.
	const maximumOutputChunks = 64
	started := time.Now()
	client.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: snapshot.Terminal.TerminalID,
		RunID:      snapshot.RunID,
		Data: []byte(fmt.Sprintf(
			"head -c %d /dev/zero; printf '\\nLARGE-OUTPUT-DONE\\n'\n",
			outputBytes,
		)),
	})
	client.waitForOutputLength(t, outputBytes)
	client.waitForOutput(t, "LARGE-OUTPUT-DONE")
	chunks, bytes := client.outputStats()
	if chunks > maximumOutputChunks {
		t.Fatalf(
			"5 MiB burst used %d terminal chunks, want at most %d",
			chunks,
			maximumOutputChunks,
		)
	}
	t.Logf(
		"received %d bytes in %d terminal chunks (%d bytes/chunk average) in %s",
		bytes,
		chunks,
		bytes/max(chunks, 1),
		time.Since(started).Round(time.Millisecond),
	)

	// A subsequent command proves the same controller connection remains live
	// after the output burst instead of being overflow-closed.
	client.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: snapshot.Terminal.TerminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'AFTER-LARGE-OUTPUT\\n'\n"),
	})
	client.waitForOutput(t, "AFTER-LARGE-OUTPUT")

	client.mu.Lock()
	defer client.mu.Unlock()
	var last uint64
	for _, item := range client.items {
		if item.Kind != terminal.StreamItemOutput {
			continue
		}
		if last != 0 && item.Sequence != last+1 {
			t.Fatalf("terminal output sequence jumped from %d to %d", last, item.Sequence)
		}
		last = item.Sequence
	}
}

func TestTerminalWriteFromNonControllerIsIgnored(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	controller := dialTerminalClient(t, url)
	intruder := dialTerminalClient(t, url)

	snapshot := createTestTerminal(t, controller)

	intruder.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: snapshot.Terminal.TerminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'INTRUDER-%d\\n' $((7*3))\n"),
	})
	controller.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: snapshot.Terminal.TerminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("printf 'OWNER-%d\\n' $((7*3))\n"),
	})
	controller.waitForOutput(t, "OWNER-21")

	if controller.outputContains("INTRUDER-21") {
		t.Fatal("non-controller input reached the PTY")
	}
	if intruder.outputContains("OWNER-21") {
		t.Fatal("terminal output streamed to a client that never attached")
	}
}

func TestTerminalTerminateStreamsFinalStatus(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	client := dialTerminalClient(t, url)

	snapshot := createTestTerminal(t, client)
	client.call(t, RPCMethodTerminalTerminate, wire.TerminalIDParams{TerminalID: snapshot.Terminal.TerminalID}, nil)

	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		statuses := client.statusItems()
		if len(statuses) > 0 {
			last := statuses[len(statuses)-1]
			if last.Status != terminal.StatusStopped {
				t.Fatalf("final status = %s, want stopped", last.Status)
			}
			if last.RunID != snapshot.RunID {
				t.Fatalf("status run id = %s, want %s", last.RunID, snapshot.RunID)
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("timed out waiting for terminal status stream item")
}

func TestTerminalNaturalExitStreamsExitCode(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	client := dialTerminalClient(t, url)

	snapshot := createTestTerminal(t, client)
	client.notify(t, RPCMethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: snapshot.Terminal.TerminalID,
		RunID:      snapshot.RunID,
		Data:       []byte("exit 5\n"),
	})

	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		statuses := client.statusItems()
		if len(statuses) > 0 {
			last := statuses[len(statuses)-1]
			if last.Status != terminal.StatusExited {
				t.Fatalf("final status = %s, want exited", last.Status)
			}
			if last.ExitCode == nil || *last.ExitCode != 5 {
				t.Fatalf("exit code = %v, want 5", last.ExitCode)
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("timed out waiting for exit status stream item")
}

// useQuietTestShell keeps login-shell startup deterministic for daemon tests.
func useQuietTestShell(t *testing.T) {
	t.Helper()
	t.Setenv("SHELL", "/bin/zsh")
	t.Setenv("ZDOTDIR", t.TempDir())
}
