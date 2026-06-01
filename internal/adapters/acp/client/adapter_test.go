package client

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"testing"
	"time"

	protocol "github.com/Aqothy/maiD/internal/adapters/acp/protocol"
)

func TestInitializeConnection(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	cmd, conn := startHelperConnection(t)
	defer cmd.Wait()
	defer conn.Close()

	resp, err := conn.InitializeConnection(ctx)
	if err != nil {
		t.Fatalf("InitializeConnection: %v", err)
	}
	if resp.ProtocolVersion != 1 {
		t.Fatalf("protocolVersion = %d, want 1", resp.ProtocolVersion)
	}
	if resp.AgentInfo == nil || resp.AgentInfo.Name != "fake-acp-agent" {
		t.Fatalf("agentInfo = %#v", resp.AgentInfo)
	}
	if conn.InitializedAt.IsZero() {
		t.Fatal("InitializedAt was not set")
	}
}

func TestInitializeConnectionRejectsVersionMismatch(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	cmd, conn := startHelperConnection(t, "version-mismatch")
	defer cmd.Wait()
	defer conn.Close()

	_, err := conn.InitializeConnection(ctx)
	if err == nil {
		t.Fatal("InitializeConnection succeeded, want error")
	}
}

func TestAuthenticate(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	cmd, conn := startHelperConnection(t, "auth")
	defer cmd.Wait()
	defer conn.Close()

	if _, err := conn.InitializeConnection(ctx); err != nil {
		t.Fatalf("InitializeConnection: %v", err)
	}
	resp, err := conn.Authenticate(ctx, "agent-login")
	if err != nil {
		t.Fatalf("Authenticate: %v", err)
	}
	if resp.Meta["authenticated"] != true {
		t.Fatalf("Authenticate response meta = %#v", resp.Meta)
	}
}

func TestAuthenticateRequiresMethodID(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	cmd, conn := startHelperConnection(t, "auth")
	defer cmd.Wait()
	defer conn.Close()

	if _, err := conn.InitializeConnection(ctx); err != nil {
		t.Fatalf("InitializeConnection: %v", err)
	}
	if _, err := conn.Authenticate(ctx, ""); err == nil {
		t.Fatal("Authenticate succeeded, want error")
	}
}

func TestAuthenticateRejectsUnadvertisedMethod(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	cmd, conn := startHelperConnection(t, "auth")
	defer cmd.Wait()
	defer conn.Close()

	if _, err := conn.InitializeConnection(ctx); err != nil {
		t.Fatalf("InitializeConnection: %v", err)
	}
	if _, err := conn.Authenticate(ctx, "missing"); err == nil {
		t.Fatal("Authenticate succeeded, want error")
	}
}

func TestLogout(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	cmd, conn := startHelperConnection(t, "logout")
	defer cmd.Wait()
	defer conn.Close()

	if _, err := conn.InitializeConnection(ctx); err != nil {
		t.Fatalf("InitializeConnection: %v", err)
	}
	if _, err := conn.Logout(ctx); err != nil {
		t.Fatalf("Logout: %v", err)
	}
}

func TestSessionMethods(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	cmd, conn := startHelperConnection(t, "sessions")
	defer cmd.Wait()
	defer conn.Close()

	if _, err := conn.InitializeConnection(ctx); err != nil {
		t.Fatalf("InitializeConnection: %v", err)
	}
	newResp, err := conn.NewSession(ctx, protocol.NewSessionRequest{Cwd: "/tmp/project", McpServers: []protocol.McpServer{}})
	if err != nil {
		t.Fatalf("NewSession: %v", err)
	}
	if newResp.SessionId != "sess_new" {
		t.Fatalf("new session id = %q", newResp.SessionId)
	}
	listResp, err := conn.ListSessions(ctx, protocol.ListSessionsRequest{})
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(listResp.Sessions) != 1 || listResp.Sessions[0].SessionId != "sess_new" {
		t.Fatalf("sessions = %#v", listResp.Sessions)
	}
	if _, err := conn.LoadSession(ctx, protocol.LoadSessionRequest{SessionId: "sess_new", Cwd: "/tmp/project", McpServers: []protocol.McpServer{}}); err != nil {
		t.Fatalf("LoadSession: %v", err)
	}
	if _, err := conn.ResumeSession(ctx, protocol.ResumeSessionRequest{SessionId: "sess_new", Cwd: "/tmp/project", McpServers: []protocol.McpServer{}}); err != nil {
		t.Fatalf("ResumeSession: %v", err)
	}
	if _, err := conn.CloseSession(ctx, "sess_new"); err != nil {
		t.Fatalf("CloseSession: %v", err)
	}
}

func startHelperConnection(t *testing.T, args ...string) (*exec.Cmd, *Connection) {
	t.Helper()
	cmdArgs := append([]string{"MAID_ACP_HELPER=1", os.Args[0], "-test.run=TestHelperProcess", "--"}, args...)
	cmd := exec.Command("env", cmdArgs...)
	cmd.Stderr = os.Stderr

	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("StdinPipe: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("StdoutPipe: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}

	return cmd, NewConnection(stdin, stdout)
}

func TestHelperProcess(t *testing.T) {
	if os.Getenv("MAID_ACP_HELPER") != "1" {
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
		Params struct {
			ProtocolVersion int `json:"protocolVersion"`
		} `json:"params"`
	}
	if err := json.Unmarshal(line, &req); err != nil {
		fmt.Fprintf(os.Stderr, "decode request: %v", err)
		os.Exit(1)
	}
	if req.Method != "initialize" || req.Params.ProtocolVersion != 1 {
		fmt.Fprintf(os.Stderr, "unexpected request: %s", line)
		os.Exit(1)
	}

	protocolVersion := 1
	if mode == "version-mismatch" {
		protocolVersion = 999
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
			"protocolVersion": protocolVersion,
			"agentCapabilities": map[string]any{
				"auth":                map[string]any{"logout": map[string]any{}},
				"loadSession":         loadSession,
				"promptCapabilities":  map[string]any{},
				"sessionCapabilities": sessionCapabilities,
			},
			"agentInfo":   map[string]any{"name": "fake-acp-agent", "version": "0.0.0"},
			"authMethods": authMethods,
		},
	}
	if err := json.NewEncoder(os.Stdout).Encode(resp); err != nil {
		fmt.Fprintf(os.Stderr, "write response: %v", err)
		os.Exit(1)
	}

	if mode == "sessions" {
		serveSessionRequests(reader)
		return
	}
	if mode != "auth" && mode != "logout" {
		return
	}
	line, err = reader.ReadBytes('\n')
	if err != nil {
		return
	}
	var nextReq struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params struct {
			MethodID string `json:"methodId"`
		} `json:"params"`
	}
	if err := json.Unmarshal(line, &nextReq); err != nil {
		fmt.Fprintf(os.Stderr, "decode auth request: %v", err)
		os.Exit(1)
	}
	if mode == "auth" {
		if nextReq.Method != "authenticate" || nextReq.Params.MethodID != "agent-login" {
			fmt.Fprintf(os.Stderr, "unexpected auth request: %s", line)
			os.Exit(1)
		}
		resp = map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(nextReq.ID), "result": map[string]any{"_meta": map[string]any{"authenticated": true}}}
	} else {
		if nextReq.Method != "logout" {
			fmt.Fprintf(os.Stderr, "unexpected logout request: %s", line)
			os.Exit(1)
		}
		resp = map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(nextReq.ID), "result": map[string]any{}}
	}
	if err := json.NewEncoder(os.Stdout).Encode(resp); err != nil {
		fmt.Fprintf(os.Stderr, "write auth response: %v", err)
		os.Exit(1)
	}
}

func serveSessionRequests(reader *bufio.Reader) {
	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			return
		}
		var req struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
		}
		if err := json.Unmarshal(line, &req); err != nil {
			fmt.Fprintf(os.Stderr, "decode session request: %v", err)
			os.Exit(1)
		}

		var result any = map[string]any{}
		switch req.Method {
		case "session/new":
			result = map[string]any{"sessionId": "sess_new"}
		case "session/list":
			result = map[string]any{"sessions": []any{map[string]any{"sessionId": "sess_new", "cwd": "/tmp/project", "title": "Test session"}}}
		case "session/load", "session/resume", "session/close":
			result = map[string]any{}
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
