package daemon

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"testing"

	"github.com/Aqothy/maiD/internal/ipc"
	"github.com/Aqothy/maiD/internal/model"
)

func TestHandleUnknownAction(t *testing.T) {
	resp := NewServer().handle(ipc.Request{Action: "nope"})
	if resp.OK {
		t.Fatal("OK = true, want false")
	}
}

func TestHandleAgentInitRequiresCommand(t *testing.T) {
	req, err := ipc.NewRequest(ipc.ActionAgentInit, ipc.AgentInitParams{})
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}

	resp := NewServer().handle(req)
	if resp.OK {
		t.Fatal("OK = true, want false")
	}
	if resp.Message != "agent init requires an ACP adapter command" {
		t.Fatalf("message = %q", resp.Message)
	}
}

func TestAgentInitSupportsMultipleConnectionsAndReusesSameName(t *testing.T) {
	s := NewServer()
	defer s.Close()

	codex := initAgent(t, s, "codex")
	gemini := initAgent(t, s, "gemini")
	if codex.Name != "codex" || gemini.Name != "gemini" {
		t.Fatalf("agent names = %q/%q, want codex/gemini", codex.Name, gemini.Name)
	}
	if codex.PID == gemini.PID {
		t.Fatalf("different agent names should start different processes; both pid %d", codex.PID)
	}

	codexAgain := initAgent(t, s, "codex")
	if codexAgain.PID != codex.PID {
		t.Fatalf("same agent name should reuse process; pid %d != %d", codexAgain.PID, codex.PID)
	}
}

func TestAgentAuthenticate(t *testing.T) {
	s := NewServer()
	defer s.Close()

	initReq, err := ipc.NewRequest(ipc.ActionAgentInit, ipc.AgentInitParams{Name: "codex", Kind: "acp", Command: helperCommand("auth")})
	if err != nil {
		t.Fatalf("NewRequest init: %v", err)
	}
	if resp := s.handle(initReq); !resp.OK {
		t.Fatalf("agent init failed: %s", resp.Message)
	}
	authReq, err := ipc.NewRequest(ipc.ActionAgentAuthenticate, ipc.AgentAuthenticateParams{Name: "codex", MethodID: "agent-login"})
	if err != nil {
		t.Fatalf("NewRequest auth: %v", err)
	}
	resp := s.handle(authReq)
	if !resp.OK {
		t.Fatalf("agent auth failed: %s", resp.Message)
	}
	var conn model.AgentConnection
	if err := json.Unmarshal(resp.Data, &conn); err != nil {
		t.Fatalf("decode connection: %v", err)
	}
	if len(conn.Metadata["authenticatedAt"]) == 0 {
		t.Fatalf("authenticatedAt metadata missing: %#v", conn.Metadata)
	}
}

func TestSessionNewAndList(t *testing.T) {
	s := NewServer()
	defer s.Close()

	initReq, err := ipc.NewRequest(ipc.ActionAgentInit, ipc.AgentInitParams{Name: "codex", Kind: "acp", Command: helperCommand("sessions")})
	if err != nil {
		t.Fatalf("NewRequest init: %v", err)
	}
	if resp := s.handle(initReq); !resp.OK {
		t.Fatalf("agent init failed: %s", resp.Message)
	}

	cwd := t.TempDir()
	newReq, err := ipc.NewRequest(ipc.ActionSessionNew, ipc.SessionNewParams{Name: "codex", Cwd: cwd})
	if err != nil {
		t.Fatalf("NewRequest session new: %v", err)
	}
	newResp := s.handle(newReq)
	if !newResp.OK {
		t.Fatalf("session new failed: %s", newResp.Message)
	}
	var thread model.AgentThread
	if err := json.Unmarshal(newResp.Data, &thread); err != nil {
		t.Fatalf("decode thread: %v", err)
	}
	if thread.ID != "sess_new" || thread.Cwd != cwd {
		t.Fatalf("thread = %#v", thread)
	}

	listReq, err := ipc.NewRequest(ipc.ActionSessionList, ipc.SessionListParams{Name: "codex"})
	if err != nil {
		t.Fatalf("NewRequest session list: %v", err)
	}
	listResp := s.handle(listReq)
	if !listResp.OK {
		t.Fatalf("session list failed: %s", listResp.Message)
	}
	var list model.AgentThreadList
	if err := json.Unmarshal(listResp.Data, &list); err != nil {
		t.Fatalf("decode thread list: %v", err)
	}
	if len(list.Threads) != 1 || list.Threads[0].ID != "sess_new" {
		t.Fatalf("thread list = %#v", list)
	}
}

func initAgent(t *testing.T, s *Server, name string) model.AgentConnection {
	t.Helper()
	req, err := ipc.NewRequest(ipc.ActionAgentInit, ipc.AgentInitParams{Name: name, Kind: "acp", Command: helperCommand()})
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	resp := s.handle(req)
	if !resp.OK {
		t.Fatalf("agent init failed: %s", resp.Message)
	}
	var conn model.AgentConnection
	if err := json.Unmarshal(resp.Data, &conn); err != nil {
		t.Fatalf("decode connection: %v", err)
	}
	return conn
}

func helperCommand(args ...string) []string {
	cmd := []string{"env", "MAID_DAEMON_ACP_HELPER=1", os.Args[0], "-test.run=TestHelperProcess", "--"}
	return append(cmd, args...)
}

func TestHelperProcess(t *testing.T) {
	if os.Getenv("MAID_DAEMON_ACP_HELPER") != "1" {
		return
	}

	mode := ""
	for i, arg := range os.Args {
		if arg == "--" && i+1 < len(os.Args) {
			mode = os.Args[i+1]
			break
		}
	}

	reader := bufio.NewReader(os.Stdin)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		fmt.Fprintf(os.Stderr, "read request: %v", err)
		os.Exit(1)
	}

	var req struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
	}
	if err := json.Unmarshal(line, &req); err != nil {
		fmt.Fprintf(os.Stderr, "decode request: %v", err)
		os.Exit(1)
	}
	if req.Method != "initialize" {
		fmt.Fprintf(os.Stderr, "unexpected method: %s", req.Method)
		os.Exit(1)
	}

	authMethods := []any{}
	if mode == "auth" {
		authMethods = []any{map[string]any{"id": "agent-login", "name": "Agent login"}}
	}
	sessionCapabilities := map[string]any{}
	loadSession := false
	if mode == "sessions" {
		loadSession = true
		sessionCapabilities = map[string]any{"list": map[string]any{}, "resume": map[string]any{}, "close": map[string]any{}}
	}
	resp := map[string]any{
		"jsonrpc": "2.0",
		"id":      json.RawMessage(req.ID),
		"result": map[string]any{
			"protocolVersion":   1,
			"agentCapabilities": map[string]any{"auth": map[string]any{"logout": map[string]any{}}, "loadSession": loadSession, "sessionCapabilities": sessionCapabilities},
			"agentInfo":         map[string]any{"name": "fake-acp-agent"},
			"authMethods":       authMethods,
		},
	}
	if err := json.NewEncoder(os.Stdout).Encode(resp); err != nil {
		fmt.Fprintf(os.Stderr, "write response: %v", err)
		os.Exit(1)
	}

	if mode == "sessions" {
		serveDaemonSessionRequests(reader)
		return
	}

	line, err = reader.ReadBytes('\n')
	if err != nil {
		return
	}
	if mode != "auth" {
		return
	}
	var authReq struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params struct {
			MethodID string `json:"methodId"`
		} `json:"params"`
	}
	if err := json.Unmarshal(line, &authReq); err != nil {
		fmt.Fprintf(os.Stderr, "decode auth request: %v", err)
		os.Exit(1)
	}
	if authReq.Method != "authenticate" || authReq.Params.MethodID != "agent-login" {
		fmt.Fprintf(os.Stderr, "unexpected auth request: %s", line)
		os.Exit(1)
	}
	resp = map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(authReq.ID), "result": map[string]any{}}
	if err := json.NewEncoder(os.Stdout).Encode(resp); err != nil {
		fmt.Fprintf(os.Stderr, "write auth response: %v", err)
		os.Exit(1)
	}
}

func serveDaemonSessionRequests(reader *bufio.Reader) {
	cwdBySession := map[string]string{}
	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			return
		}
		var req struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params struct {
				Cwd string `json:"cwd"`
			} `json:"params"`
		}
		if err := json.Unmarshal(line, &req); err != nil {
			fmt.Fprintf(os.Stderr, "decode session request: %v", err)
			os.Exit(1)
		}

		var result any = map[string]any{}
		switch req.Method {
		case "session/new":
			cwdBySession["sess_new"] = req.Params.Cwd
			result = map[string]any{"sessionId": "sess_new"}
		case "session/list":
			result = map[string]any{"sessions": []any{map[string]any{"sessionId": "sess_new", "cwd": cwdBySession["sess_new"], "title": "Test session"}}}
		default:
			fmt.Fprintf(os.Stderr, "unexpected session request: %s", line)
			os.Exit(1)
		}
		resp := map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(req.ID), "result": result}
		if err := json.NewEncoder(os.Stdout).Encode(resp); err != nil {
			fmt.Fprintf(os.Stderr, "write session response: %v", err)
			os.Exit(1)
		}
	}
}
