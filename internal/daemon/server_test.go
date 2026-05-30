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

func helperCommand() []string {
	return []string{"env", "MAID_DAEMON_ACP_HELPER=1", os.Args[0], "-test.run=TestHelperProcess"}
}

func TestHelperProcess(t *testing.T) {
	if os.Getenv("MAID_DAEMON_ACP_HELPER") != "1" {
		return
	}

	line, err := bufio.NewReader(os.Stdin).ReadBytes('\n')
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

	resp := map[string]any{
		"jsonrpc": "2.0",
		"id":      json.RawMessage(req.ID),
		"result": map[string]any{
			"protocolVersion":   1,
			"agentCapabilities": map[string]any{"sessionCapabilities": map[string]any{}},
			"agentInfo":         map[string]any{"name": "fake-acp-agent"},
			"authMethods":       []any{},
		},
	}
	if err := json.NewEncoder(os.Stdout).Encode(resp); err != nil {
		fmt.Fprintf(os.Stderr, "write response: %v", err)
		os.Exit(1)
	}

	_, _ = bufio.NewReader(os.Stdin).ReadBytes('\n')
}
