package daemon

// The daemon tests' harness: a server on a test-scoped data directory and a
// real WebSocket JSON-RPC client that records every notification in arrival
// order, the way a thin UI replica would.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"maps"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Aqothy/jsonrpc2"
	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
	"github.com/coder/websocket"
)

// TestMain points MAID_DATA_DIR at a temporary directory, so code that
// resolves it (NewServer, the ACP registry) never touches the user's.
func TestMain(m *testing.M) {
	// The fake ACP agent is this binary, and it ends by being killed, which
	// would leave its directory behind. It has no use for one.
	if os.Getenv("MAID_DAEMON_ACP_HELPER") == "1" {
		os.Exit(m.Run())
	}
	dataDir, err := os.MkdirTemp("", "maid-daemon-tests-")
	if err != nil {
		panic(err)
	}
	if err := os.Setenv("MAID_DATA_DIR", dataDir); err != nil {
		_ = os.RemoveAll(dataDir)
		panic(err)
	}
	code := m.Run()
	_ = os.RemoveAll(dataDir)
	os.Exit(code)
}

// newTestServer starts a server on its own data directory.
func newTestServer(t testing.TB) *Server {
	t.Helper()
	return newTestServerAt(t, t.TempDir())
}

// newTestServerAt starts a server on dir; a second one on the same dir is
// the daemon after a restart.
func newTestServerAt(t testing.TB, dir string) *Server {
	t.Helper()
	return newTestServerWith(t, dir, nil)
}

// newTestServerWith starts a server with test drivers besides the real ones.
func newTestServerWith(t testing.TB, dir string, extra map[provider.DriverKind]provider.Driver) *Server {
	t.Helper()
	all := maps.Clone(drivers)
	maps.Copy(all, extra)
	s, err := newServer(newLoggerFromEnv(), dir, all)
	if err != nil {
		t.Fatalf("start server: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func newWSTestServer(t testing.TB, s *Server) string {
	t.Helper()
	server := httptest.NewServer(s.handler())
	t.Cleanup(server.Close)
	return "ws" + strings.TrimPrefix(server.URL, "http") + "/rpc"
}

type recordingClient struct {
	conn *jsonrpc2.Connection
	url  string

	mu                 sync.Mutex
	changed            chan struct{}
	threadEvents       []orchestration.ThreadEvent
	listItems          []orchestration.ThreadListItem
	terminalListItems  []wire.TerminalListStreamItem
	terminalListCursor int
	projectLists       []wire.ProjectList
	acpLists           []wire.ACPRegistryList
	// terminalOutput is the output of every terminal stream the client
	// opened.
	terminalOutput     bytes.Buffer
	providerQuestions  []wire.ProviderQuestion
	optionsUpdates     []wire.ProviderOptionsResult
	optionsInvalidated []wire.ProviderOptionsInvalidated
}

func dialRecordingClient(t testing.TB, url string) *recordingClient {
	t.Helper()
	c := &recordingClient{url: url, changed: make(chan struct{})}
	ws, _, err := websocket.Dial(context.Background(), url, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	// Snapshots of long threads exceed the 32KiB library default.
	ws.SetReadLimit(-1)
	c.conn = jsonrpc2.NewWebSocketConnection(context.Background(), wsJSONRPC{conn: ws}, c)
	t.Cleanup(func() { _ = c.conn.Close() })
	return c
}

// newRecordingClient serves s over a fresh WebSocket listener and dials it.
func newRecordingClient(t testing.TB, s *Server) *recordingClient {
	t.Helper()
	return dialRecordingClient(t, newWSTestServer(t, s))
}

func (c *recordingClient) Handle(ctx context.Context, req *jsonrpc2.Request) (any, error) {
	if req.IsCall() {
		return nil, jsonrpc2.ErrNotHandled
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	defer c.signalLocked()
	switch req.Method {
	case wire.MethodThreadEvent:
		var event orchestration.ThreadEvent
		if err := decodeRPCParams(req, &event); err != nil {
			return nil, err
		}
		c.threadEvents = append(c.threadEvents, event)
	case wire.MethodThreadList:
		var item orchestration.ThreadListItem
		if err := decodeRPCParams(req, &item); err != nil {
			return nil, err
		}
		c.listItems = append(c.listItems, item)
	case wire.MethodTerminalSubscribeList:
		var item wire.TerminalListStreamItem
		if err := decodeRPCParams(req, &item); err != nil {
			return nil, err
		}
		c.terminalListItems = append(c.terminalListItems, item)
	case wire.MethodProjectList:
		var list wire.ProjectList
		if err := decodeRPCParams(req, &list); err != nil {
			return nil, err
		}
		c.projectLists = append(c.projectLists, list)
	case wire.MethodACPRegistryList:
		var list wire.ACPRegistryList
		if err := decodeRPCParams(req, &list); err != nil {
			return nil, err
		}
		c.acpLists = append(c.acpLists, list)
	case wire.MethodProviderQuestionAsked:
		var question wire.ProviderQuestion
		if err := decodeRPCParams(req, &question); err != nil {
			return nil, err
		}
		c.providerQuestions = append(c.providerQuestions, question)
	case wire.MethodProviderOptionsUpdated:
		var update wire.ProviderOptionsResult
		if err := decodeRPCParams(req, &update); err != nil {
			return nil, err
		}
		c.optionsUpdates = append(c.optionsUpdates, update)
	case wire.MethodProviderOptionsInvalidated:
		var invalidated wire.ProviderOptionsInvalidated
		if err := decodeRPCParams(req, &invalidated); err != nil {
			return nil, err
		}
		c.optionsInvalidated = append(c.optionsInvalidated, invalidated)
	}
	return nil, nil
}

// signalLocked wakes waiters after a change; the caller holds mu.
func (c *recordingClient) signalLocked() {
	close(c.changed)
	c.changed = make(chan struct{})
}

func (c *recordingClient) callErr(method string, params any, result any) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return c.conn.Call(ctx, method, params).Await(ctx, result)
}

func (c *recordingClient) call(t testing.TB, method string, params any, result any) {
	t.Helper()
	if err := c.callErr(method, params, result); err != nil {
		t.Fatalf("%s: %v", method, err)
	}
}

func (c *recordingClient) notify(t *testing.T, method string, params any) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := c.conn.Notify(ctx, method, params); err != nil {
		t.Fatalf("notify %s: %v", method, err)
	}
}

func (c *recordingClient) commandErr(params wire.CommandParams) (orchestration.CommandResult, error) {
	var result orchestration.CommandResult
	err := c.callErr(wire.MethodThreadCommand, params, &result)
	return result, err
}

func (c *recordingClient) command(t *testing.T, params wire.CommandParams) orchestration.CommandResult {
	t.Helper()
	result, err := c.commandErr(params)
	if err != nil {
		t.Fatalf("thread.command: %v", err)
	}
	return result
}

// addProject adds dir as a project, as the app's folder picker does, and
// returns its canonical path.
func (c *recordingClient) addProject(t *testing.T, dir string) string {
	t.Helper()
	var project wire.Project
	c.call(t, wire.MethodProjectAdd, wire.ProjectParams{Path: dir}, &project)
	return project.Path
}

// createThread starts a chat with the instance in cwd, adding cwd as a
// project first.
func (c *recordingClient) createThread(t *testing.T, instance provider.InstanceID, cwd string) orchestration.CommandResult {
	t.Helper()
	cwd = c.addProject(t, cwd)
	create := orchestration.CreateThread{Workspace: wire.Workspace{Cwd: cwd}, Participant: orchestration.NewParticipant{Instance: instance}}
	return c.command(t, wire.CommandParams{CreateThread: &create})
}

func (c *recordingClient) deliver(t *testing.T, thread orchestration.ThreadID, text string) orchestration.CommandResult {
	t.Helper()
	return c.command(t, wire.CommandParams{Deliver: &orchestration.Deliver{Thread: thread, Body: orchestration.MessageBody{Text: text}}})
}

// subscribe opens a thread as the app does: sync, then subscribe.
func (c *recordingClient) subscribe(t *testing.T, thread orchestration.ThreadID) orchestration.ThreadSnapshot {
	t.Helper()
	c.call(t, wire.MethodThreadSync, wire.ThreadParams{Thread: thread}, nil)
	var snapshot orchestration.ThreadSnapshot
	c.call(t, wire.MethodThreadSubscribe, wire.ThreadParams{Thread: thread}, &snapshot)
	return snapshot
}

// waitEvent waits for a thread event that matches and returns the first.
func (c *recordingClient) waitEvent(t *testing.T, desc string, match func(orchestration.ThreadEvent) bool) orchestration.ThreadEvent {
	t.Helper()
	var found orchestration.ThreadEvent
	c.waitFor(t, desc, func() bool {
		index := slices.IndexFunc(c.threadEvents, match)
		if index >= 0 {
			found = c.threadEvents[index]
		}
		return index >= 0
	})
	return found
}

// waitSettled waits for the turn a delivery started to settle, and returns
// it with the entries its events streamed.
func (c *recordingClient) waitSettled(t *testing.T, thread orchestration.ThreadID, delivery orchestration.DeliveryID) orchestration.TurnView {
	t.Helper()
	var started orchestration.TurnID
	scanned := 0
	c.waitFor(t, "the turn of "+string(delivery)+" to settle", func() bool {
		for ; scanned < len(c.threadEvents); scanned++ {
			event := c.threadEvents[scanned]
			switch {
			case event.Thread != thread:
			case event.Kind == orchestration.EventDelivery && event.Delivery.ID == delivery && event.Delivery.Turn != "":
				started = event.Delivery.Turn
			case event.Kind == orchestration.EventTurn && started != "" && event.Turn.ID == started && event.Turn.State.Settled():
				return true
			}
		}
		return false
	})
	c.mu.Lock()
	defer c.mu.Unlock()
	var turn orchestration.TurnView
	at := map[string]int{}
	for _, event := range c.threadEvents {
		switch {
		case event.Thread != thread:
		case event.Kind == orchestration.EventTurn && event.Turn.ID == started:
			entries := turn.Entries
			turn = *event.Turn
			turn.Entries = entries
		case event.Kind == orchestration.EventEntry && event.Turn.ID == started:
			if index, ok := at[event.Entry.Ref]; ok {
				turn.Entries[index] = *event.Entry
			} else {
				at[event.Entry.Ref] = len(turn.Entries)
				turn.Entries = append(turn.Entries, *event.Entry)
			}
		case event.Kind == orchestration.EventText && event.Text.Turn == started:
			if index, ok := at[event.Text.Entry]; ok {
				turn.Entries[index].Text += event.Text.Text
			}
		}
	}
	return turn
}

// waitFor waits until done holds of what the client recorded; done runs
// under the client's lock.
func (c *recordingClient) waitFor(t testing.TB, desc string, done func() bool) {
	t.Helper()
	deadline := time.After(15 * time.Second)
	for {
		c.mu.Lock()
		ok, changed := done(), c.changed
		c.mu.Unlock()
		if ok {
			return
		}
		select {
		case <-changed:
		case <-deadline:
			c.mu.Lock()
			recorded := len(c.threadEvents)
			c.mu.Unlock()
			t.Fatalf("timed out waiting for %s; %d thread events recorded", desc, recorded)
		}
	}
}

// waitUntil polls a condition outside any client's notifications.
func waitUntil(t *testing.T, desc string, done func() bool) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for !done() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", desc)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func waitForFile(t *testing.T, path string) {
	t.Helper()
	waitUntil(t, path, func() bool {
		_, err := os.Stat(path)
		return err == nil
	})
}

// commandCode is the CommandErrorCode a refused command came back with.
func commandCode(err error) (int64, orchestration.ErrorCode) {
	var wireErr *jsonrpc2.WireError
	if !errors.As(err, &wireErr) {
		return 0, ""
	}
	var data struct {
		Code orchestration.ErrorCode `json:"code"`
	}
	_ = json.Unmarshal(wireErr.Data, &data)
	return wireErr.Code, data.Code
}
