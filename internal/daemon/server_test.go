package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
)

func TestProviderStartValidation(t *testing.T) {
	for _, tc := range []struct {
		name string
		spec provider.InstanceSpec
		want string
	}{
		{name: "instance id", spec: provider.InstanceSpec{}, want: "provider start requires instanceId"},
		{name: "config", spec: provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "acp"}, want: "missing ACP config"},
		{name: "command", spec: acpInstanceSpec("codex", "codex", nil), want: "ACP config requires command"},
		{name: "malformed config", spec: provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "acp", Config: json.RawMessage(`{"command":`)}, want: "decode ACP config"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := NewServer()
			defer server.Close()
			_, err := server.StartProvider(context.Background(), tc.spec, false)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v, want error containing %q", err, tc.want)
			}
		})
	}
}

func TestProviderStartReusesSameInstance(t *testing.T) {
	s := NewServer()
	defer s.Close()

	first := startProvider(t, s, "codex", helperCommand())
	second := startProvider(t, s, "codex", helperCommand())
	if second.PID != first.PID {
		t.Fatalf("same provider instance should reuse process; pid %d != %d", second.PID, first.PID)
	}
}

func TestProviderRestartSettlesActiveTurnFromReplacedProcess(t *testing.T) {
	s := NewServer()
	defer s.Close()

	dir := t.TempDir()
	readyPath := dir + "/ready"
	releasePath := dir + "/release"
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("codex", "codex", helperCommand("blocked-sessions", readyPath, releasePath)), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}

	threadID := orchestration.ThreadID("thread-restart-settles-turn")
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-create-restart-settle", ThreadID: threadID, Title: "Restart settle", ProviderInstanceID: "codex", Cwd: dir}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-turn-restart-settle", ThreadID: threadID, Message: &orchestration.CommandMessage{MessageID: "msg-restart", Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	waitForFile(t, readyPath)

	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("codex", "codex", helperCommand("sessions")), true); err != nil {
		t.Fatalf("provider restart: %v", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		thread, ok := s.orchestration.Thread(threadID)
		if ok && thread.LatestTurn != nil && thread.LatestTurn.State == orchestration.TurnStateError && thread.Session != nil && thread.Session.ActiveTurnID == "" {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	thread, _ := s.orchestration.Thread(threadID)
	t.Fatalf("thread after restart = %#v, want replaced provider turn settled as error", thread)
}

// TestProviderCloseKillsWrappedAgentProcessTree guards against orphaning the
// real agent when the configured command is a wrapper (npx/npm exec): killing
// only the direct child would leak the agent process it spawned. The fake agent
// runs behind a non-exec'ing shell so it is a grandchild of the daemon.
func TestProviderCloseKillsWrappedAgentProcessTree(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("process-group kill is unix-only")
	}
	s := NewServer()
	dir := t.TempDir()
	pidPath := dir + "/agent.pid"
	// The trailing "exit $?" keeps the shell from exec-replacing itself with the
	// helper, so the helper stays a grandchild like npx's spawned agent.
	inner := fmt.Sprintf("MAID_DAEMON_ACP_HELPER=1 MAID_HELPER_PIDFILE='%s' '%s' -test.run=TestHelperProcess -- lingering-sessions; exit $?", pidPath, os.Args[0])
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("wrapped", "wrapped", []string{"/bin/sh", "-c", inner}), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}
	waitForFile(t, pidPath)
	raw, err := os.ReadFile(pidPath)
	if err != nil {
		t.Fatalf("read helper pidfile: %v", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		t.Fatalf("parse helper pid %q: %v", raw, err)
	}
	if err := syscall.Kill(pid, 0); err != nil {
		t.Fatalf("wrapped agent process %d not alive before close: %v", pid, err)
	}

	if err := s.Close(); err != nil {
		t.Fatalf("server close: %v", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, 0); err != nil {
			return // grandchild died with the process group
		}
		time.Sleep(10 * time.Millisecond)
	}
	_ = syscall.Kill(pid, 9)
	t.Fatalf("wrapped agent process %d survived server close (leaked agent)", pid)
}

func startProvider(t *testing.T, s *Server, id string, command []string) providerConnectionForTest {
	t.Helper()
	conn, err := s.StartProvider(context.Background(), acpInstanceSpec(provider.InstanceID(id), id, command), false)
	if err != nil {
		t.Fatalf("provider start failed: %v", err)
	}
	return providerConnectionForTest{PID: conn.PID}
}

type providerConnectionForTest struct{ PID int }

func acpInstanceSpec(id provider.InstanceID, name string, command []string) provider.InstanceSpec {
	config, err := json.Marshal(map[string]any{"command": command})
	if err != nil {
		panic(err)
	}
	return provider.InstanceSpec{InstanceID: id, Name: name, Driver: "acp", Config: config}
}

func helperCommand(args ...string) []string {
	cmd := []string{"env", "MAID_DAEMON_ACP_HELPER=1", os.Args[0], "-test.run=TestHelperProcess", "--"}
	return append(cmd, args...)
}

func waitForFile(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", path)
}

func waitForHelperFile(path string) {
	for {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func assertPermissionResponse(reader *bufio.Reader, expectedOption string) {
	request := map[string]any{
		"jsonrpc": "2.0",
		"id":      "perm_1",
		"method":  "session/request_permission",
		"params": map[string]any{
			"sessionId": "sess_new",
			"toolCall":  map[string]any{"toolCallId": "tool_1", "title": "Edit file"},
			"options": []any{
				map[string]any{"kind": "allow_once", "name": "Allow", "optionId": "allow"},
				map[string]any{"kind": "reject_once", "name": "Reject", "optionId": "reject"},
			},
		},
	}
	if err := json.NewEncoder(os.Stdout).Encode(request); err != nil {
		fmt.Fprintf(os.Stderr, "write permission request: %v", err)
		os.Exit(1)
	}
	line, err := reader.ReadBytes('\n')
	if err != nil {
		fmt.Fprintf(os.Stderr, "read permission response: %v", err)
		os.Exit(1)
	}
	var resp struct {
		ID     string          `json:"id"`
		Error  json.RawMessage `json:"error"`
		Result struct {
			Outcome struct {
				Outcome  string `json:"outcome"`
				OptionID string `json:"optionId"`
			} `json:"outcome"`
		} `json:"result"`
	}
	if err := json.Unmarshal(line, &resp); err != nil {
		fmt.Fprintf(os.Stderr, "decode permission response: %v", err)
		os.Exit(1)
	}
	if len(resp.Error) > 0 {
		fmt.Fprintf(os.Stderr, "permission response error: %s", resp.Error)
		os.Exit(1)
	}
	if resp.ID != "perm_1" || resp.Result.Outcome.Outcome != "selected" || resp.Result.Outcome.OptionID != expectedOption {
		fmt.Fprintf(os.Stderr, "permission response = %s, want selected %s", line, expectedOption)
		os.Exit(1)
	}
}

// requestPermissionThenExpectCancelled emits a session/request_permission and
// waits for the client (via the daemon) to answer it. It asserts the outcome is
// "cancelled", which is what the daemon must return once a session/cancel
// cancels the pending permission wait. A session/cancel notification may arrive
// before or after the permission response, so it is skipped here.
func requestPermissionThenExpectCancelled(reader *bufio.Reader) {
	request := map[string]any{
		"jsonrpc": "2.0",
		"id":      "perm_1",
		"method":  "session/request_permission",
		"params": map[string]any{
			"sessionId": "sess_new",
			"toolCall":  map[string]any{"toolCallId": "tool_1", "title": "Edit file"},
			"options": []any{
				map[string]any{"kind": "allow_once", "name": "Allow", "optionId": "allow"},
				map[string]any{"kind": "reject_once", "name": "Reject", "optionId": "reject"},
			},
		},
	}
	if err := json.NewEncoder(os.Stdout).Encode(request); err != nil {
		fmt.Fprintf(os.Stderr, "write permission request: %v", err)
		os.Exit(1)
	}
	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			fmt.Fprintf(os.Stderr, "read permission response: %v", err)
			os.Exit(1)
		}
		var msg struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Result struct {
				Outcome struct {
					Outcome string `json:"outcome"`
				} `json:"outcome"`
			} `json:"result"`
		}
		if err := json.Unmarshal(line, &msg); err != nil {
			fmt.Fprintf(os.Stderr, "decode permission response: %v", err)
			os.Exit(1)
		}
		if msg.Method == "session/cancel" {
			continue
		}
		if len(msg.ID) == 0 {
			continue
		}
		if msg.Result.Outcome.Outcome != "cancelled" {
			fmt.Fprintf(os.Stderr, "permission outcome = %s, want cancelled", line)
			os.Exit(1)
		}
		return
	}
}

func TestHelperProcess(t *testing.T) {
	if os.Getenv("MAID_DAEMON_ACP_HELPER") != "1" {
		return
	}
	if pidPath := os.Getenv("MAID_HELPER_PIDFILE"); pidPath != "" {
		if err := os.WriteFile(pidPath, []byte(strconv.Itoa(os.Getpid())), 0o644); err != nil {
			fmt.Fprintf(os.Stderr, "write helper pidfile: %v", err)
			os.Exit(1)
		}
	}

	helperArgs := []string{}
	for i, arg := range os.Args {
		if arg == "--" && i+1 < len(os.Args) {
			helperArgs = os.Args[i+1:]
			break
		}
	}
	mode := ""
	if len(helperArgs) > 0 {
		mode = helperArgs[0]
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
	if mode == "auth" || mode == "rich-sessions" {
		authMethods = []any{map[string]any{"id": "agent-login", "name": "Agent login"}}
	}
	sessionCapabilities := map[string]any{}
	loadSession := false
	if isSessionMode(mode) {
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

	if mode == "scripted-sessions" {
		serveScriptedSessionRequests(reader)
		return
	}
	if isSessionMode(mode) {
		var readyPath, releasePath, cancelPath string
		if mode == "blocked-sessions" || mode == "cancelable-blocked-sessions" {
			if len(helperArgs) < 3 {
				fmt.Fprintf(os.Stderr, "%s requires ready and release/cancel paths\n", mode)
				os.Exit(1)
			}
			readyPath = helperArgs[1]
			if mode == "blocked-sessions" {
				releasePath = helperArgs[2]
			} else {
				cancelPath = helperArgs[2]
			}
		}
		serveDaemonSessionRequests(reader, mode, readyPath, releasePath, cancelPath)
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

func isSessionMode(mode string) bool {
	switch mode {
	case "sessions", "slow-sessions", "streaming-sessions", "blocked-sessions", "cancelable-blocked-sessions",
		"permission-deny-sessions", "permission-allow-sessions", "cancel-permission-sessions", "lingering-sessions",
		"rich-sessions", "scripted-sessions":
		return true
	}
	return false
}

// fakeSessionConfigOptions is the ACP configOptions payload the rich-sessions
// fake agent advertises: a mode selector and a model selector (the two
// categories maiD projects onto SessionBinding.ConfigOptions).
func fakeSessionConfigOptions(modeValue string, modelValue string) []any {
	return []any{
		map[string]any{"type": "select", "id": "mode", "name": "Mode", "category": "mode", "currentValue": modeValue, "options": []any{
			map[string]any{"name": "Ask", "value": "ask"},
			map[string]any{"name": "Plan", "value": "plan"},
		}},
		map[string]any{"type": "select", "id": "model", "name": "Model", "category": "model", "currentValue": modelValue, "options": []any{
			map[string]any{"name": "Test Model 1", "value": "test-model-1"},
			map[string]any{"name": "Test Model 2", "value": "test-model-2"},
		}},
	}
}

func serveDaemonSessionRequests(reader *bufio.Reader, mode string, readyPath string, releasePath string, cancelPath string) {
	slowPrompt := mode == "slow-sessions"
	delayAfterUpdate := mode == "streaming-sessions"
	cancelPermission := mode == "cancel-permission-sessions"
	linger := mode == "lingering-sessions"
	rich := mode == "rich-sessions"
	expectedPermissionOption := ""
	switch mode {
	case "permission-deny-sessions":
		expectedPermissionOption = "reject"
	case "permission-allow-sessions":
		expectedPermissionOption = "allow"
	}

	cwdBySession := map[string]string{}
	var blockedPromptID json.RawMessage
	modeValue := "ask"
	modelValue := "test-model-1"
	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			if linger {
				// Mimic real agents (e.g. claude-code-acp) that do not exit on
				// stdin EOF: only a kill of the process group reaps them.
				// (A sleep loop, not select{}, so the Go runtime's deadlock
				// detector does not terminate the helper.)
				for {
					time.Sleep(time.Hour)
				}
			}
			return
		}
		var req struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params struct {
				Cwd       string `json:"cwd"`
				SessionID string `json:"sessionId"`
				MethodID  string `json:"methodId"`
				ConfigID  string `json:"configId"`
				Value     string `json:"value"`
			} `json:"params"`
		}
		if err := json.Unmarshal(line, &req); err != nil {
			fmt.Fprintf(os.Stderr, "decode session request: %v", err)
			os.Exit(1)
		}

		var result any = map[string]any{}
		switch req.Method {
		case "$/cancel_request":
			// Protocol-level request cancellation is a notification; a real
			// agent treats a cancel for an already-completed request as a no-op.
			continue
		case "session/cancel":
			if len(blockedPromptID) > 0 {
				if cancelPath != "" {
					if err := os.WriteFile(cancelPath, []byte("cancelled"), 0o644); err != nil {
						fmt.Fprintf(os.Stderr, "write prompt cancelled marker: %v", err)
						os.Exit(1)
					}
				}
				resp := map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(blockedPromptID), "result": map[string]any{"stopReason": "cancelled"}}
				if err := json.NewEncoder(os.Stdout).Encode(resp); err != nil {
					fmt.Fprintf(os.Stderr, "write cancelled prompt response: %v", err)
					os.Exit(1)
				}

				blockedPromptID = nil
			}
			// Cancellation is a notification; there is no response to write.
			continue
		case "authenticate":
			if req.Params.MethodID != "agent-login" {
				fmt.Fprintf(os.Stderr, "unexpected authenticate request: %s", line)
				os.Exit(1)
			}
		case "logout":
		case "session/close":
		case "session/set_config_option":
			switch req.Params.ConfigID {
			case "mode":
				modeValue = req.Params.Value
			case "model":
				modelValue = req.Params.Value
			default:
				fmt.Fprintf(os.Stderr, "unexpected set_config_option request: %s", line)
				os.Exit(1)
			}
			result = map[string]any{"configOptions": fakeSessionConfigOptions(modeValue, modelValue)}
		case "session/new":
			cwdBySession["sess_new"] = req.Params.Cwd
			newSession := map[string]any{"sessionId": "sess_new"}
			if rich {
				newSession["configOptions"] = fakeSessionConfigOptions(modeValue, modelValue)
			}
			result = newSession
		case "session/list":
			result = map[string]any{"sessions": []any{map[string]any{"sessionId": "sess_new", "cwd": cwdBySession["sess_new"], "title": "Test session"}}}
		case "session/load":
			sessionID := req.Params.SessionID
			if sessionID == "" {
				sessionID = "sess_new"
			}
			notification := map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"sessionId": sessionID, "update": map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "replayed"}}}}
			if err := json.NewEncoder(os.Stdout).Encode(notification); err != nil {
				fmt.Fprintf(os.Stderr, "write session load update: %v", err)
				os.Exit(1)
			}
		case "session/prompt":
			if cancelPermission {
				requestPermissionThenExpectCancelled(reader)
				resp := map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(req.ID), "result": map[string]any{"stopReason": "cancelled"}}
				if err := json.NewEncoder(os.Stdout).Encode(resp); err != nil {
					fmt.Fprintf(os.Stderr, "write cancelled prompt response: %v", err)
					os.Exit(1)
				}
				continue
			}
			if expectedPermissionOption != "" {
				assertPermissionResponse(reader, expectedPermissionOption)
			}
			if readyPath != "" {
				if err := os.WriteFile(readyPath, []byte("ready"), 0o644); err != nil {
					fmt.Fprintf(os.Stderr, "write prompt ready marker: %v", err)
					os.Exit(1)
				}
			}
			if cancelPath != "" {
				blockedPromptID = append(json.RawMessage(nil), req.ID...)
				continue
			}
			if releasePath != "" {
				waitForHelperFile(releasePath)
			}
			if slowPrompt {
				time.Sleep(500 * time.Millisecond)
			}
			if rich {
				for _, update := range []map[string]any{
					{"sessionUpdate": "available_commands_update", "availableCommands": []any{map[string]any{"name": "compact", "description": "Compact the conversation"}}},
					{"sessionUpdate": "session_info_update", "title": "Agent set title"},
					{"sessionUpdate": "usage_update", "used": 1200, "size": 200000, "cost": map[string]any{"amount": 0.42, "currency": "USD"}},
				} {
					richNotification := map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"sessionId": "sess_new", "update": update}}
					if err := json.NewEncoder(os.Stdout).Encode(richNotification); err != nil {
						fmt.Fprintf(os.Stderr, "write rich session update: %v", err)
						os.Exit(1)
					}
				}
			}
			notification := map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"sessionId": "sess_new", "update": map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "hi"}}}}
			if err := json.NewEncoder(os.Stdout).Encode(notification); err != nil {
				fmt.Fprintf(os.Stderr, "write session update: %v", err)
				os.Exit(1)
			}
			if delayAfterUpdate {
				time.Sleep(200 * time.Millisecond)
			}
			result = map[string]any{"stopReason": "end_turn"}
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

// serveScriptedSessionRequests is the multi-client-test fake agent: it mints a
// distinct session id per session/new (so concurrent threads on one instance
// do not collide) and interprets the prompt text as a behavior script:
//
//	"stream <n> [width] [delayMs]"  emit n agent_message_chunk updates
//	                      (width-padded, optionally paced like a real agent)
//	"tools <n>"           emit n distinct tool_call updates (per-event client
//	                      traffic — agent text is buffered server-side)
//	"permission"          request permission, answer follows the chosen option
//	"block"               park the prompt until session/cancel resolves it
//	anything else         a single "hi" chunk
//
// The loop is fully event-driven (parked prompts and pending permission
// requests are keyed state, not blocking reads), so prompts on other sessions
// keep being served while one session waits on an approval or a cancel.
func serveScriptedSessionRequests(reader *bufio.Reader) {
	writeMessage := func(msg map[string]any) {
		if err := json.NewEncoder(os.Stdout).Encode(msg); err != nil {
			fmt.Fprintf(os.Stderr, "scripted agent write: %v", err)
			os.Exit(1)
		}
	}
	writeResult := func(id json.RawMessage, result any) {
		writeMessage(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
	}
	writeChunk := func(sessionID string, text string) {
		writeMessage(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{
			"sessionId": sessionID,
			"update":    map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": text}},
		}})
	}

	type pendingPermission struct {
		promptID  json.RawMessage
		sessionID string
	}
	sessionCounter := 0
	permissionCounter := 0
	parkedPrompts := map[string]json.RawMessage{}        // sessionID -> blocked session/prompt id
	pendingPermissions := map[string]pendingPermission{} // permission request id -> prompt to settle

	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			return
		}
		var msg struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params struct {
				Cwd       string `json:"cwd"`
				SessionID string `json:"sessionId"`
				Prompt    []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"prompt"`
			} `json:"params"`
			Result struct {
				Outcome struct {
					Outcome  string `json:"outcome"`
					OptionID string `json:"optionId"`
				} `json:"outcome"`
			} `json:"result"`
		}
		if err := json.Unmarshal(line, &msg); err != nil {
			fmt.Fprintf(os.Stderr, "scripted agent decode: %v", err)
			os.Exit(1)
		}

		if msg.Method == "" && len(msg.ID) > 0 {
			// A response to one of our permission requests.
			pending, ok := pendingPermissions[strings.Trim(string(msg.ID), `"`)]
			if !ok {
				continue
			}
			delete(pendingPermissions, strings.Trim(string(msg.ID), `"`))
			if msg.Result.Outcome.Outcome == "cancelled" {
				writeResult(pending.promptID, map[string]any{"stopReason": "cancelled"})
				continue
			}
			writeChunk(pending.sessionID, "perm:"+msg.Result.Outcome.OptionID)
			writeResult(pending.promptID, map[string]any{"stopReason": "end_turn"})
			continue
		}

		switch msg.Method {
		case "$/cancel_request":
			// Protocol-level cancellation notification; nothing to settle here.
		case "session/new":
			sessionCounter++
			writeResult(msg.ID, map[string]any{"sessionId": fmt.Sprintf("sess-%d", sessionCounter)})
		case "session/load", "session/resume":
			// Resume support without history replay: enough for a provider
			// restart to rebind a thread's session.
			writeResult(msg.ID, map[string]any{})
		case "session/cancel":
			if promptID, ok := parkedPrompts[msg.Params.SessionID]; ok {
				delete(parkedPrompts, msg.Params.SessionID)
				writeResult(promptID, map[string]any{"stopReason": "cancelled"})
			}
			// Cancellation is a notification; nothing else to write.
		case "session/prompt":
			text := ""
			for _, block := range msg.Params.Prompt {
				if block.Type == "text" {
					text = block.Text
					break
				}
			}
			fields := strings.Fields(text)
			switch {
			case len(fields) >= 2 && fields[0] == "stream":
				count, err := strconv.Atoi(fields[1])
				if err != nil {
					fmt.Fprintf(os.Stderr, "scripted agent stream count %q: %v", fields[1], err)
					os.Exit(1)
				}
				width := 0
				if len(fields) >= 3 {
					if width, err = strconv.Atoi(fields[2]); err != nil {
						fmt.Fprintf(os.Stderr, "scripted agent stream width %q: %v", fields[2], err)
						os.Exit(1)
					}
				}
				delay := time.Duration(0)
				if len(fields) >= 4 {
					delayMs, err := strconv.Atoi(fields[3])
					if err != nil {
						fmt.Fprintf(os.Stderr, "scripted agent stream delay %q: %v", fields[3], err)
						os.Exit(1)
					}
					delay = time.Duration(delayMs) * time.Millisecond
				}
				for i := 0; i < count; i++ {
					chunk := fmt.Sprintf("w%d ", i)
					if pad := width - len(chunk); pad > 0 {
						chunk += strings.Repeat("x", pad)
					}
					writeChunk(msg.Params.SessionID, chunk)
					if delay > 0 {
						time.Sleep(delay)
					}
				}
				writeResult(msg.ID, map[string]any{"stopReason": "end_turn"})
			case len(fields) >= 2 && fields[0] == "tools":
				count, err := strconv.Atoi(fields[1])
				if err != nil {
					fmt.Fprintf(os.Stderr, "scripted agent tools count %q: %v", fields[1], err)
					os.Exit(1)
				}
				for i := 0; i < count; i++ {
					writeMessage(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{
						"sessionId": msg.Params.SessionID,
						"update":    map[string]any{"sessionUpdate": "tool_call", "toolCallId": fmt.Sprintf("tool-%d", i), "title": fmt.Sprintf("tool %d", i), "status": "completed"},
					}})
				}
				writeResult(msg.ID, map[string]any{"stopReason": "end_turn"})
			case len(fields) >= 1 && fields[0] == "permission":
				permissionCounter++
				permID := fmt.Sprintf("perm-%d", permissionCounter)
				pendingPermissions[permID] = pendingPermission{promptID: append(json.RawMessage(nil), msg.ID...), sessionID: msg.Params.SessionID}
				writeMessage(map[string]any{"jsonrpc": "2.0", "id": permID, "method": "session/request_permission", "params": map[string]any{
					"sessionId": msg.Params.SessionID,
					"toolCall":  map[string]any{"toolCallId": "tool-" + permID, "title": "Edit file"},
					"options": []any{
						map[string]any{"kind": "allow_once", "name": "Allow", "optionId": "allow"},
						map[string]any{"kind": "reject_once", "name": "Reject", "optionId": "reject"},
					},
				}})
			case len(fields) >= 1 && fields[0] == "block":
				parkedPrompts[msg.Params.SessionID] = append(json.RawMessage(nil), msg.ID...)
			default:
				writeChunk(msg.Params.SessionID, "hi")
				writeResult(msg.ID, map[string]any{"stopReason": "end_turn"})
			}
		default:
			fmt.Fprintf(os.Stderr, "scripted agent unexpected request: %s", line)
			os.Exit(1)
		}
	}
}

// TestInvariantViolationShutsServerDownAndSurfacesFromRunWebSocket pins the
// fatal-path ownership: an orchestration invariant violation records the
// typed error, runs the full server shutdown (so group-isolated agent
// processes are killed, not orphaned), and surfaces the error from
// RunWebSocket — main is the sole owner of process exit; neither the engine
// nor the server calls os.Exit.
func TestInvariantViolationShutsServerDownAndSurfacesFromRunWebSocket(t *testing.T) {
	s := NewServer()
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("codex", "codex", helperCommand("streaming-sessions")), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}

	runErr := make(chan error, 1)
	go func() { runErr <- s.RunWebSocket("127.0.0.1:0") }()
	// Give the listener a beat to install itself so Close tears it down.
	time.Sleep(50 * time.Millisecond)

	violation := &orchestration.InvariantViolationError{Cause: "test boom"}
	s.handleInvariantViolation(violation)

	select {
	case err := <-runErr:
		var got *orchestration.InvariantViolationError
		if !errors.As(err, &got) || got != violation {
			t.Fatalf("RunWebSocket returned %v, want the reported InvariantViolationError", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("RunWebSocket did not return after an invariant violation")
	}
	// The shutdown ran: a second Close is idempotent and providers are gone.
	if err := s.Close(); err != nil {
		t.Fatalf("second Close err = %v, want idempotent nil", err)
	}
}
