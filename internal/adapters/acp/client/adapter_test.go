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

	line, err := bufio.NewReader(os.Stdin).ReadBytes('\n')
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
	resp := map[string]any{
		"jsonrpc": "2.0",
		"id":      json.RawMessage(req.ID),
		"result": map[string]any{
			"protocolVersion": protocolVersion,
			"agentCapabilities": map[string]any{
				"promptCapabilities":  map[string]any{},
				"sessionCapabilities": map[string]any{},
			},
			"agentInfo":   map[string]any{"name": "fake-acp-agent", "version": "0.0.0"},
			"authMethods": []any{},
		},
	}
	if err := json.NewEncoder(os.Stdout).Encode(resp); err != nil {
		fmt.Fprintf(os.Stderr, "write response: %v", err)
		os.Exit(1)
	}
}
