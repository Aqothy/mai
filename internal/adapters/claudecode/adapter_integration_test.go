package claudecode

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// TestMain doubles as the fake Claude Code CLI: the adapter spawns real
// processes, so tests point Config.Command at the test binary itself and the
// CLAUDE_FAKE_CLI re-entry speaks scripted stream-json on stdio.
func TestMain(m *testing.M) {
	if os.Getenv("CLAUDE_FAKE_CLI") == "1" {
		fakeCLIMain()
		return
	}
	os.Exit(m.Run())
}

func fakeWrite(value any) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return
	}
	os.Stdout.Write(append(encoded, '\n'))
}

func fakeCLIMain() {
	sessionID := ""
	for index, arg := range os.Args {
		if (arg == "--session-id" || arg == "--resume") && index+1 < len(os.Args) {
			sessionID = os.Args[index+1]
		}
	}
	// Session processes log one line per launch and per control request in
	// the session cwd, so tests can assert flags and control traffic. The
	// probe has no session and runs in the home directory, so it logs nothing.
	logTo := func(name, line string) {
		if sessionID == "" {
			return
		}
		if file, err := os.OpenFile(name, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
			fmt.Fprintln(file, line)
			_ = file.Close()
		}
	}
	logTo(fakeLaunchLog, strings.Join(os.Args[1:], " "))
	if sessionID == "" {
		sessionID = "fake-session"
	}
	replayUserMessages := slices.Contains(os.Args, "--replay-user-messages")
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 0, 1<<20), 16<<20)
	initSent := false
	slowTurn := false
	emitInit := func() {
		if initSent {
			return
		}
		initSent = true
		fakeWrite(map[string]any{
			"type": "system", "subtype": "init", "session_id": sessionID,
			"model": "fake-model", "permissionMode": "default",
			"slash_commands": []string{"compact"}, "tools": []string{"Bash"},
		})
	}
	emitResult := func(extra map[string]any) {
		result := map[string]any{
			"type": "result", "subtype": "success", "is_error": false,
			"result": "done", "session_id": sessionID, "total_cost_usd": 0.01,
			"usage":      map[string]any{"input_tokens": 5, "cache_read_input_tokens": 100, "output_tokens": 7},
			"modelUsage": map[string]any{"fake-model": map[string]any{"contextWindow": 200000, "costUSD": 0.01}},
		}
		for key, value := range extra {
			result[key] = value
		}
		fakeWrite(result)
	}
	// echo acknowledges a written message the way the CLI does when it takes
	// one into a query, at its start or folded in at a tool boundary.
	echo := func(message map[string]any) {
		if uuid, _ := message["uuid"].(string); replayUserMessages && uuid != "" {
			fakeWrite(map[string]any{"type": "user", "isReplay": true, "uuid": uuid, "session_id": sessionID, "parent_tool_use_id": nil, "message": message["message"]})
		}
	}
	emitText := func(text string) {
		fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_start", "index": 0, "content_block": map[string]any{"type": "text", "text": ""}}})
		fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "text_delta", "text": text}}})
		fakeWrite(map[string]any{"type": "assistant", "session_id": sessionID, "message": map[string]any{"id": "msg_text", "role": "assistant", "content": []map[string]any{{"type": "text", "text": text}}}})
		fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_stop", "index": 0}})
	}
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var message map[string]any
		if json.Unmarshal(line, &message) != nil {
			continue
		}
		switch message["type"] {
		case "control_request":
			requestID, _ := message["request_id"].(string)
			request, _ := message["request"].(map[string]any)
			subtype, _ := request["subtype"].(string)
			if encoded, err := json.Marshal(request); err == nil {
				logTo(fakeControlLog, string(encoded))
			}
			respond := func(payload any) {
				fakeWrite(map[string]any{"type": "control_response", "response": map[string]any{"subtype": "success", "request_id": requestID, "response": payload}})
			}
			switch subtype {
			case "initialize":
				respond(map[string]any{
					"commands": []map[string]any{{"name": "compact", "description": "Compact context", "argumentHint": "[instructions]"}},
					"models": []map[string]any{
						{"value": "default", "resolvedModel": "fake-model", "displayName": "Default", "description": "Recommended", "supportsEffort": true, "supportedEffortLevels": []string{"low", "high"}},
						{"value": "fake-model", "resolvedModel": "fake-model", "displayName": "Fake", "description": "Test model"},
						{"value": "other", "resolvedModel": "other-model", "displayName": "Other", "description": "Another model"},
					},
					"account":                 map[string]any{"email": "fake@example.com", "subscriptionType": "Claude Max", "apiProvider": "firstParty"},
					"current_permission_mode": "default",
				})
			case "interrupt":
				respond(map[string]any{})
				if slowTurn {
					slowTurn = false
					emitResult(map[string]any{"subtype": "error_during_execution", "terminal_reason": "aborted_streaming", "result": ""})
				}
			default:
				respond(map[string]any{})
			}
		case "control_response":
			// The permission answer resumes the scripted turn.
			response, _ := message["response"].(map[string]any)
			inner, _ := response["response"].(map[string]any)
			if behavior, _ := inner["behavior"].(string); behavior == "allow" {
				fakeWrite(map[string]any{"type": "user", "session_id": sessionID, "message": map[string]any{"role": "user", "content": []map[string]any{{"type": "tool_result", "tool_use_id": "toolu_1", "content": "hi", "is_error": false}}}})
			}
			emitResult(nil)
		case "user":
			emitInit()
			text := ""
			if inner, ok := message["message"].(map[string]any); ok {
				switch content := inner["content"].(type) {
				case string:
					text = content
				case []any:
					for _, block := range content {
						if mapped, ok := block.(map[string]any); ok && mapped["type"] == "text" {
							text += mapped["text"].(string)
						}
					}
				}
			}
			if slowTurn {
				slowTurn = false
				if strings.Contains(text, "FOLD") {
					// Folded in at a tool boundary: one result answers both.
					echo(message)
					emitResult(nil)
					continue
				}
				// The running query ends before a boundary, so the message
				// runs as one more query with its own result.
				emitResult(nil)
				echo(message)
				emitText("Later reply")
				emitResult(nil)
				continue
			}
			echo(message)
			if strings.Contains(text, "WAKE") {
				emitText("Started a background task")
				emitResult(nil)
				// The task finishing wakes the CLI with no message written.
				emitText("Background task finished")
				emitResult(nil)
				continue
			}
			if strings.Contains(text, "SIGNED_OUT") {
				fakeWrite(map[string]any{"type": "assistant", "session_id": sessionID, "error": "authentication_failed", "message": map[string]any{"id": "msg_err", "role": "assistant", "content": []map[string]any{{"type": "text", "text": "Invalid API key · Please run /login"}}}})
				emitResult(map[string]any{"subtype": "success", "is_error": true, "result": "Invalid API key · Please run /login"})
				continue
			}
			// What the CLI reports on its own, scripted by prompt.
			zeroUsage := map[string]any{"usage": map[string]any{}, "modelUsage": map[string]any{}, "total_cost_usd": 0.02}
			if strings.Contains(text, "COMPACT") {
				fakeWrite(map[string]any{"type": "system", "subtype": "status", "status": "compacting", "session_id": sessionID})
				fakeWrite(map[string]any{"type": "system", "subtype": "compact_boundary", "uuid": "boundary-1", "session_id": sessionID})
				// The CLI resends the last kept assistant message.
				fakeWrite(map[string]any{"type": "assistant", "uuid": "hello-1", "session_id": sessionID, "message": map[string]any{"id": "msg_1", "role": "assistant", "content": []map[string]any{{"type": "text", "text": "Hello world"}}}})
				emitResult(zeroUsage)
				continue
			}
			if strings.Contains(text, "CLEAR") {
				sessionID = "22222222-2222-4222-8222-222222222222"
				fakeWrite(map[string]any{"type": "conversation_reset", "new_conversation_id": sessionID, "uuid": "reset-1", "session_id": sessionID})
				emitResult(zeroUsage)
				continue
			}
			if strings.Contains(text, "MODEL") {
				fakeWrite(map[string]any{"type": "system", "subtype": "init", "session_id": sessionID, "model": "other-model", "permissionMode": "plan"})
				emitResult(zeroUsage)
				continue
			}
			if strings.Contains(text, "BACKGROUND") {
				// Two commands run in the background; the first finishes and
				// wakes the CLI, the second outlives the session.
				for _, id := range []string{"toolu_bg1", "toolu_bg2"} {
					fakeWrite(map[string]any{"type": "assistant", "session_id": sessionID, "message": map[string]any{"id": "msg_" + id, "role": "assistant", "content": []map[string]any{{"type": "tool_use", "id": id, "name": "Bash", "input": map[string]any{"command": "sleep 60", "run_in_background": true}}}}})
					fakeWrite(map[string]any{"type": "user", "session_id": sessionID, "tool_use_result": map[string]any{"backgroundTaskId": "task-" + id}, "message": map[string]any{"role": "user", "content": []map[string]any{{"type": "tool_result", "tool_use_id": id, "content": "Command running in background"}}}})
				}
				emitResult(nil)
				fakeWrite(map[string]any{"type": "system", "subtype": "task_notification", "task_id": "task-toolu_bg1", "tool_use_id": "toolu_bg1", "status": "completed", "summary": "Background command completed (exit code 0)", "session_id": sessionID})
				emitText("The first command finished")
				emitResult(nil)
				continue
			}
			if strings.Contains(text, "BLOCKED") {
				fakeWrite(map[string]any{"type": "system", "subtype": "informational", "level": "warning", "prevent_continuation": true, "content": "Prompt blocked by hook", "session_id": sessionID})
				emitResult(zeroUsage)
				continue
			}
			if strings.Contains(text, "SLOW") {
				slowTurn = true
				fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_start", "index": 0, "content_block": map[string]any{"type": "text", "text": ""}}})
				fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "text_delta", "text": "Working..."}}})
				continue
			}
			fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_start", "index": 0, "content_block": map[string]any{"type": "text", "text": ""}}})
			fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "text_delta", "text": "Hello "}}})
			fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "text_delta", "text": "world"}}})
			fakeWrite(map[string]any{"type": "assistant", "uuid": "hello-1", "session_id": sessionID, "message": map[string]any{"id": "msg_1", "role": "assistant", "content": []map[string]any{{"type": "text", "text": "Hello world"}}}})
			fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_stop", "index": 0}})
			fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_start", "index": 1, "content_block": map[string]any{"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": map[string]any{}}}})
			fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_delta", "index": 1, "delta": map[string]any{"type": "input_json_delta", "partial_json": `{"command":"ec`}}})
			fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_delta", "index": 1, "delta": map[string]any{"type": "input_json_delta", "partial_json": `ho hi"}`}}})
			fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_stop", "index": 1}})
			fakeWrite(map[string]any{"type": "control_request", "request_id": "perm-1", "request": map[string]any{
				"subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": "toolu_1",
				"input":                  map[string]any{"command": "echo hi"},
				"permission_suggestions": []map[string]any{{"type": "addRules", "rules": []map[string]any{{"toolName": "Bash"}}, "behavior": "allow", "destination": "localSettings"}},
				// A request the CLI allows only once.
				"suppress_always_allow_rule": strings.Contains(text, "ONCE"),
			}})
		}
	}
}

func openTestInstance(t *testing.T) (*Instance, chan provider.RuntimeEvent, string) {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatalf("os.Executable: %v", err)
	}
	configDir := t.TempDir()
	config, err := json.Marshal(Config{Command: []string{executable}, Env: map[string]string{"CLAUDE_FAKE_CLI": "1", "GORACE": "atexit_sleep_ms=0"}, ConfigDir: configDir})
	if err != nil {
		t.Fatal(err)
	}
	events := make(chan provider.RuntimeEvent, 256)
	instance, err := OpenInstance(context.Background(), provider.InstanceSpec{InstanceID: "claude-code", Name: "Claude Code", Config: config}, func(event provider.RuntimeEvent) {
		events <- event
	})
	if err != nil {
		t.Fatalf("OpenInstance: %v", err)
	}
	t.Cleanup(func() { _ = instance.Close() })
	return instance, events, configDir
}

func waitForEvent(t *testing.T, events chan provider.RuntimeEvent, match func(provider.RuntimeEvent) bool) provider.RuntimeEvent {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case event := <-events:
			if match(event) {
				return event
			}
		case <-deadline:
			t.Fatal("timed out waiting for event")
		}
	}
}

func TestOpenInstanceProbe(t *testing.T) {
	instance, _, _ := openTestInstance(t)
	info := instance.Info()
	if info.Status != provider.InstanceStatusInitialized {
		t.Fatalf("status = %q", info.Status)
	}
	if info.Auth.Status != provider.AuthStatusAuthenticated {
		t.Fatalf("auth = %#v, want authenticated from probe account", info.Auth)
	}
}

// A turn the API refuses for authentication marks the provider signed out,
// which is what makes clients offer sign-in; sign-in runs `claude auth login`.
func TestAuthenticationFailureOffersSignIn(t *testing.T) {
	instance, events, _ := openTestInstance(t)
	if _, err := instance.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1", Cwd: t.TempDir()}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := instance.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "SIGNED_OUT"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventTurnCompleted
	})
	if status := instance.Info().Auth.Status; status != provider.AuthStatusUnauthenticated {
		t.Fatalf("auth status = %q, want unauthenticated", status)
	}

	result, err := instance.Authenticate(context.Background(), provider.AuthenticateInput{MethodID: authMethodConsole})
	if err != nil || result.Terminal == nil {
		t.Fatalf("Authenticate = %#v, %v; want a terminal command", result, err)
	}
	if want := append(slices.Clone(instance.config.Command), "auth", "login", "--console"); !slices.Equal(result.Terminal.Argv, want) {
		t.Fatalf("argv = %v, want %v", result.Terminal.Argv, want)
	}
	if !slices.Contains(result.Terminal.Env, "CLAUDE_CONFIG_DIR="+instance.config.ConfigDir) {
		t.Fatalf("env = %v, want the instance's config dir", result.Terminal.Env)
	}
}

func TestTurnLifecycleWithApproval(t *testing.T) {
	instance, events, _ := openTestInstance(t)
	cwd := t.TempDir()
	result, err := instance.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1", Cwd: cwd})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if result.Session.ProviderSessionID == "" || result.Session.ThreadID != "thread-1" {
		t.Fatalf("session = %#v", result.Session)
	}
	if model, ok := provider.CurrentConfigString(result.Session.ConfigOptions, "model"); !ok || model != "default" {
		t.Fatalf("model option = %q %v", model, ok)
	}
	if mode, ok := provider.CurrentConfigString(result.Session.ConfigOptions, "permission_mode"); !ok || mode != "default" {
		t.Fatalf("mode option = %q %v", mode, ok)
	}
	metadata := waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventThreadMetadataUpdate
	})
	if commands := metadata.Payload.SlashCommands; len(commands) != 1 || commands[0].Name != "compact" || !commands[0].HasInput || commands[0].InputHint != "[instructions]" {
		t.Fatalf("slash commands = %#v, want compact with its argument hint", commands)
	}

	if err := instance.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventTurnStarted && event.TurnID == "turn-1"
	})
	streamed := ""
	waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		if event.Type == provider.RuntimeEventContentDelta && event.Payload.StreamKind == provider.RuntimeContentAssistantText {
			streamed += event.Payload.Delta
		}
		return streamed == "Hello world"
	})
	started := waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventItemStarted && event.ItemID == "toolu_1"
	})
	if started.Payload.ItemType != provider.ItemKindCommandExecution {
		t.Fatalf("tool item = %#v", started.Payload)
	}
	updated := waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventItemUpdated && event.ItemID == "toolu_1" && event.Payload.ToolCall != nil && event.Payload.ToolCall.Command != ""
	})
	if updated.Payload.ToolCall.Command != "echo hi" {
		t.Fatalf("streamed tool input = %#v", updated.Payload.ToolCall)
	}
	opened := waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventRequestOpened
	})
	if opened.Payload.RequestType != provider.RuntimeRequestCommandExecution || len(opened.Payload.Options) != 3 {
		t.Fatalf("approval = %#v", opened.Payload)
	}
	if err := instance.RespondToRequest(context.Background(), provider.RespondToRequestInput{ThreadID: "thread-1", RequestID: opened.RequestID, Decision: provider.ApprovalDecisionAccept}); err != nil {
		t.Fatalf("RespondToRequest: %v", err)
	}
	waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventRequestResolved && event.Payload.Decision == provider.ApprovalDecisionAccept
	})
	completed := waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventItemCompleted && event.ItemID == "toolu_1"
	})
	if completed.Payload.ToolCall == nil || completed.Payload.ToolCall.Output != "hi" || completed.Payload.ItemStatus != provider.ItemStatusCompleted {
		t.Fatalf("tool completion = %#v", completed.Payload)
	}
	usage := waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventThreadTokenUsage && event.Payload.TokenUsage != nil && event.Payload.TokenUsage.MaxTokens > 0
	})
	if usage.Payload.TokenUsage.UsedTokens != 112 || usage.Payload.TokenUsage.MaxTokens != 200000 {
		t.Fatalf("usage = %#v", usage.Payload.TokenUsage)
	}
	turnDone := waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventTurnCompleted && event.TurnID == "turn-1"
	})
	if turnDone.Payload.TurnState != provider.RuntimeTurnCompleted {
		t.Fatalf("turn completion = %#v", turnDone.Payload)
	}
}

// startSlowTurn starts turn-1 on a fake CLI that keeps it running until the
// next written message.
func startSlowTurn(t *testing.T) (*Instance, chan provider.RuntimeEvent) {
	t.Helper()
	instance, events, _ := openTestInstance(t)
	if _, err := instance.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1", Cwd: t.TempDir()}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := instance.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "SLOW work"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventContentDelta && event.TurnID == "turn-1"
	})
	return instance, events
}

// A steer the CLI folds into the running query is answered by that query's
// single result, which must end the turn rather than wait for another.
func TestFoldedSteerEndsWithTheRunningQuery(t *testing.T) {
	instance, events := startSlowTurn(t)
	if err := instance.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "FOLD this in", Steer: true}); err != nil {
		t.Fatalf("steer: %v", err)
	}
	done := waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventTurnCompleted
	})
	if done.TurnID != "turn-1" || done.Payload.TurnState != provider.RuntimeTurnCompleted {
		t.Fatalf("completion = %#v, want turn-1 completed", done)
	}
	// The turn is over, so a late steer reports it and orchestration sends
	// the message as the next turn instead.
	if err := instance.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "late", Steer: true}); !errors.Is(err, provider.ErrTurnNotRunning) {
		t.Fatalf("steer after the turn ended err = %v, want ErrTurnNotRunning", err)
	}
}

// A steer the CLI could not fold in runs as one more query after the running
// one's result. Both results belong to the one turn: it ends after the reply.
func TestUnfoldedSteerKeepsTheTurnOpenForItsQuery(t *testing.T) {
	instance, events := startSlowTurn(t)
	if err := instance.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "after this", Steer: true}); err != nil {
		t.Fatalf("steer: %v", err)
	}
	reply := ""
	done := waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		if event.Type == provider.RuntimeEventContentDelta && event.TurnID == "turn-1" {
			reply += event.Payload.Delta
		}
		return event.Type == provider.RuntimeEventTurnCompleted
	})
	if done.TurnID != "turn-1" || !strings.Contains(reply, "Later reply") {
		t.Fatalf("completion = %#v after reply %q, want turn-1 to end after the steer's reply", done, reply)
	}
}

// Output the CLI produces on its own gets a turn of its own, so it is never
// attributed to no turn or to the user's next one.
func TestCLIStartedOutputGetsItsOwnTurn(t *testing.T) {
	instance, events, _ := openTestInstance(t)
	if _, err := instance.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1", Cwd: t.TempDir()}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := instance.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "WAKE later"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventTurnCompleted && event.TurnID == "turn-1"
	})
	started := waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventTurnStarted
	})
	if started.TurnID == "" || started.TurnID == "turn-1" {
		t.Fatalf("CLI-started turn id = %q, want a fresh one", started.TurnID)
	}
	delta := waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventContentDelta
	})
	done := waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventTurnCompleted
	})
	if delta.TurnID != started.TurnID || done.TurnID != started.TurnID {
		t.Fatalf("delta turn %q, completion turn %q, want both %q", delta.TurnID, done.TurnID, started.TurnID)
	}
}

// The thread follows what the CLI reports on its own, as the terminal shows
// it: a compaction as one item (and the message it resends afterwards only
// once), a cleared conversation's new session, a model or mode changed from
// inside the CLI, and warnings such as a prompt a hook blocked. Local
// commands report no usage, which must not empty the context meter.
func TestThreadFollowsTheCLIReports(t *testing.T) {
	instance, events, _ := openTestInstance(t)
	cwd := t.TempDir()
	if _, err := instance.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-r", Cwd: cwd}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	turn := func(id, prompt string) []provider.RuntimeEvent {
		t.Helper()
		if err := instance.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-r", TurnID: id, Input: prompt}); err != nil {
			t.Fatalf("SendTurn %s: %v", id, err)
		}
		var seen []provider.RuntimeEvent
		for {
			event := waitForEvent(t, events, func(provider.RuntimeEvent) bool { return true })
			seen = append(seen, event)
			if event.Type == provider.RuntimeEventTurnCompleted && event.TurnID == id {
				return seen
			}
		}
	}
	usage := func(seen []provider.RuntimeEvent) int {
		for _, event := range seen {
			if event.Type == provider.RuntimeEventThreadTokenUsage && event.Payload.TokenUsage != nil {
				return event.Payload.TokenUsage.UsedTokens
			}
		}
		return -1
	}

	// A request the CLI allows only once offers no lasting approval.
	if err := instance.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-r", TurnID: "t1", Input: "hello ONCE"}); err != nil {
		t.Fatal(err)
	}
	opened := waitForEvent(t, events, func(event provider.RuntimeEvent) bool { return event.Type == provider.RuntimeEventRequestOpened })
	var offered []string
	for _, option := range opened.Payload.Options {
		offered = append(offered, option.ID)
	}
	if !slices.Equal(offered, []string{"accept", "decline"}) {
		t.Fatalf("options = %q", offered)
	}
	if err := instance.RespondToRequest(context.Background(), provider.RespondToRequestInput{ThreadID: "thread-r", RequestID: opened.RequestID, Decision: provider.ApprovalDecisionAccept}); err != nil {
		t.Fatal(err)
	}
	waitForEvent(t, events, func(event provider.RuntimeEvent) bool { return event.Type == provider.RuntimeEventTurnCompleted })

	compact := turn("t2", "COMPACT")
	var kept string
	var compaction []string
	for _, event := range compact {
		if event.Type == provider.RuntimeEventContentDelta {
			kept += event.Payload.Delta
		}
		if event.Payload.ItemType == provider.ItemKindContextCompaction {
			compaction = append(compaction, string(event.Type)+" "+event.ItemID[:len("compaction:")]+" "+string(event.Payload.ItemStatus))
		}
	}
	if kept != "" || !slices.Equal(compaction, []string{"item.started compaction: in_progress", "item.completed compaction: completed"}) {
		t.Fatalf("compaction turn: text %q, items %q", kept, compaction)
	}
	if used := usage(compact); used != 112 {
		t.Fatalf("context after a local command = %d, want the last turn's 112", used)
	}

	blocked := turn("t3", "BLOCKED")
	if !slices.ContainsFunc(blocked, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventRuntimeWarning && event.Payload.Message == "Prompt blocked by hook"
	}) {
		t.Fatalf("no warning for the blocked prompt: %#v", blocked)
	}

	model := turn("t4", "MODEL")
	options := func(seen []provider.RuntimeEvent) []provider.ConfigOption {
		for _, event := range seen {
			if event.Type == provider.RuntimeEventConfigOptionsUpdated {
				return event.Payload.ConfigOptions
			}
		}
		return nil
	}(model)
	selected, _ := provider.CurrentConfigString(options, "model")
	mode, _ := provider.CurrentConfigString(options, "permission_mode")
	if selected != "other" || mode != "plan" {
		t.Fatalf("options after /model and plan mode = %q, %q", selected, mode)
	}

	cleared := turn("t5", "CLEAR")
	if !slices.ContainsFunc(cleared, func(event provider.RuntimeEvent) bool { return event.Payload.Title == "Cleared context" }) {
		t.Fatalf("no cleared-context item: %#v", cleared)
	}
	result, err := instance.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-r", Cwd: cwd})
	if err != nil || result.Session.ProviderSessionID != "22222222-2222-4222-8222-222222222222" {
		t.Fatalf("session after /clear = %q, %v", result.Session.ProviderSessionID, err)
	}
}

// A command run in the background shows as running in the turn that started
// it until its task ends, then completes there with the task's summary; one
// still running when the CLI stops ends interrupted.
func TestBackgroundTaskRunsUntilItsNotification(t *testing.T) {
	instance, events, _ := openTestInstance(t)
	if _, err := instance.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-bg", Cwd: t.TempDir()}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := instance.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-bg", TurnID: "turn-bg", Input: "BACKGROUND"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	type step struct {
		item, turn, event string
		status            provider.ItemStatus
		output            string
	}
	var steps []step
	record := func(event provider.RuntimeEvent) {
		if strings.HasPrefix(event.ItemID, "toolu_bg") && event.Type != provider.RuntimeEventItemStarted {
			steps = append(steps, step{event.ItemID, event.TurnID, string(event.Type), event.Payload.ItemStatus, event.Payload.ToolCall.Output})
		}
	}
	// The wake-up turn's completion comes last.
	for completions := 0; completions < 2; {
		event := waitForEvent(t, events, func(provider.RuntimeEvent) bool { return true })
		record(event)
		if event.Type == provider.RuntimeEventTurnCompleted {
			completions++
		}
	}
	if err := instance.StopSession(context.Background(), provider.StopSessionInput{ThreadID: "thread-bg"}); err != nil {
		t.Fatalf("StopSession: %v", err)
	}
	for len(events) > 0 {
		record(<-events)
	}
	want := []step{
		{"toolu_bg1", "turn-bg", "item.updated", provider.ItemStatusInProgress, "Command running in background"},
		{"toolu_bg2", "turn-bg", "item.updated", provider.ItemStatusInProgress, "Command running in background"},
		{"toolu_bg1", "turn-bg", "item.completed", provider.ItemStatusCompleted, "Background command completed (exit code 0)"},
		{"toolu_bg2", "turn-bg", "item.completed", provider.ItemStatusInterrupted, "Command running in background"},
	}
	if !slices.Equal(steps, want) {
		t.Fatalf("background steps = %+v", steps)
	}
}

// Closing the instance (a provider restart) kills the CLI mid-turn. No result
// will arrive, so the turn must still settle instead of running forever.
func TestClosingMidTurnInterruptsTheTurn(t *testing.T) {
	instance, events := startSlowTurn(t)
	if err := instance.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	done := waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventTurnCompleted
	})
	if done.TurnID != "turn-1" || done.Payload.TurnState != provider.RuntimeTurnInterrupted {
		t.Fatalf("completion = %#v, want turn-1 interrupted", done)
	}
}

const (
	fakeLaunchLog  = "fake-cli-launches.log"
	fakeControlLog = "fake-cli-controls.log"
)

func fakeLaunches(t *testing.T, cwd string) []string {
	t.Helper()
	return fakeLog(t, cwd, fakeLaunchLog)
}

func fakeLog(t *testing.T, cwd, name string) []string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(cwd, name))
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(data)), "\n")
}

// Effort changes apply to the live process through apply_flag_settings, even
// mid-turn, without relaunching it.
func TestEffortChangeAppliesInSession(t *testing.T) {
	instance, events, _ := openTestInstance(t)
	cwd := t.TempDir()
	start := provider.StartSessionInput{ThreadID: "thread-effort", Cwd: cwd, ConfigSelections: []provider.ConfigOptionSelection{{OptionID: "effort", Value: "default"}}}
	if _, err := instance.StartSession(context.Background(), start); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if launch := fakeLaunches(t, cwd)[0]; strings.Contains(launch, "--effort") {
		t.Fatalf("model-selected effort launched with %q", launch)
	}
	if err := instance.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-effort", TurnID: "turn-slow", Input: "SLOW work"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventContentDelta && event.TurnID == "turn-slow"
	})
	for _, value := range []string{"high", "default"} {
		if err := instance.SetConfigOption(context.Background(), provider.SetConfigOptionInput{ThreadID: "thread-effort", OptionID: "effort", Value: value}); err != nil {
			t.Fatalf("SetConfigOption(%q): %v", value, err)
		}
	}
	if launches := fakeLaunches(t, cwd); len(launches) != 1 {
		t.Fatalf("launches = %q, want the process kept", launches)
	}
	var applied []string
	for _, line := range fakeLog(t, cwd, fakeControlLog) {
		if strings.Contains(line, `"apply_flag_settings"`) {
			applied = append(applied, line)
		}
	}
	want := []string{
		`{"settings":{"effortLevel":"high"},"subtype":"apply_flag_settings"}`,
		`{"settings":{"effortLevel":null},"subtype":"apply_flag_settings"}`,
	}
	if !slices.Equal(applied, want) {
		t.Fatalf("apply_flag_settings requests = %q, want %q", applied, want)
	}
}

func writeTranscriptFixture(t *testing.T, configDir, cwd, sessionID string) string {
	t.Helper()
	// The CLI names the project directory after the real path of its cwd.
	realCwd, err := filepath.EvalSymlinks(cwd)
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(configDir, "projects", sanitizePath(realCwd))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, sessionID+".jsonl")
	lines := []string{
		`{"type":"queue-operation","operation":"enqueue"}`,
		fmt.Sprintf(`{"type":"user","uuid":"u1","parentUuid":null,"timestamp":"2026-08-21T10:00:00Z","sessionId":%q,"cwd":%q,"message":{"role":"user","content":"Fix the bug"}}`, sessionID, cwd),
		fmt.Sprintf(`{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"2026-08-21T10:00:05Z","sessionId":%q,"message":{"id":"msg_1","role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}`, sessionID),
		fmt.Sprintf(`{"type":"assistant","uuid":"a2","parentUuid":"a1","timestamp":"2026-08-21T10:00:06Z","sessionId":%q,"message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_9","name":"Bash","input":{"command":"make test"}}]}}`, sessionID),
		fmt.Sprintf(`{"type":"user","uuid":"u2","parentUuid":"a2","timestamp":"2026-08-21T10:00:08Z","sessionId":%q,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_9","content":"ok","is_error":false}]}}`, sessionID),
		fmt.Sprintf(`{"type":"assistant","uuid":"a3","parentUuid":"u2","timestamp":"2026-08-21T10:00:09Z","sessionId":%q,"message":{"id":"msg_2","role":"assistant","content":[{"type":"text","text":"Done."}]}}`, sessionID),
		// A generated title never replaces the prompt; one the user chose does.
		fmt.Sprintf(`{"type":"ai-title","aiTitle":"Generated title","sessionId":%q}`, sessionID),
		fmt.Sprintf(`{"type":"custom-title","customTitle":"Fix the bug quickly","sessionId":%q}`, sessionID),
	}
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestStartSessionReplaysTranscript(t *testing.T) {
	instance, events, configDir := openTestInstance(t)
	cwd := t.TempDir()
	sessionID := "11111111-2222-3333-4444-555555555555"
	writeTranscriptFixture(t, configDir, cwd, sessionID)
	cursor, _ := json.Marshal(sessionID)
	result, err := instance.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-r", Cwd: cwd, ResumeCursor: cursor, ReplayHistory: true})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if result.HistoryUnavailable {
		t.Fatal("history should be available")
	}
	byType := map[provider.RuntimeEventType]int{}
	var toolCompleted, userItem, turnCompleted *provider.RuntimeEvent
	for index := range result.Replay {
		event := result.Replay[index]
		byType[event.Type]++
		if event.Type == provider.RuntimeEventItemCompleted && event.ItemID == "toolu_9" {
			toolCompleted = &result.Replay[index]
		}
		if event.Type == provider.RuntimeEventItemCompleted && event.Payload.ItemType == provider.ItemKindUserMessage {
			userItem = &result.Replay[index]
		}
		if event.Type == provider.RuntimeEventTurnCompleted {
			turnCompleted = &result.Replay[index]
		}
	}
	if byType[provider.RuntimeEventTurnStarted] != 1 || turnCompleted == nil {
		t.Fatalf("replay turns = %#v", byType)
	}
	if userItem == nil || userItem.Payload.Detail != "Fix the bug" {
		t.Fatalf("user item = %#v", userItem)
	}
	if toolCompleted == nil || toolCompleted.Payload.ToolCall == nil || toolCompleted.Payload.ToolCall.Output != "ok" {
		t.Fatalf("tool completion = %#v", toolCompleted)
	}
	deltas := map[provider.RuntimeContentStreamKind]string{}
	for _, event := range result.Replay {
		if event.Type == provider.RuntimeEventContentDelta {
			deltas[event.Payload.StreamKind] += event.Payload.Delta
		}
	}
	if deltas[provider.RuntimeContentAssistantText] != "Done." || deltas[provider.RuntimeContentReasoningText] != "hmm" {
		t.Fatalf("deltas = %#v", deltas)
	}
	var sawTitle, sawCommands bool
	for _, event := range result.Replay {
		if event.Type == provider.RuntimeEventThreadMetadataUpdate {
			if event.Payload.Title == "Fix the bug quickly" {
				sawTitle = true
			}
			if len(event.Payload.SlashCommands) > 0 {
				sawCommands = true
			}
		}
	}
	if !sawTitle || !sawCommands {
		t.Fatalf("replay metadata missing: title=%v commands=%v", sawTitle, sawCommands)
	}
	// Live, the CLI streams no title; the transcript's is shown once a turn
	// ends.
	if err := instance.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-r", TurnID: "turn-live", Input: "BLOCKED"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventThreadMetadataUpdate && event.Payload.Title == "Fix the bug quickly"
	})
	// Deterministic ids: replaying twice yields identical event ids.
	transcript, err := instance.readTranscript(sessionID)
	if err != nil {
		t.Fatal(err)
	}
	again := replayEventsFromTranscript("thread-r", transcript)
	for index, event := range again {
		if result.Replay[index].EventID != event.EventID {
			t.Fatalf("replay ids diverge at %d: %q vs %q", index, result.Replay[index].EventID, event.EventID)
		}
	}
}

func TestTranscriptSessionManagement(t *testing.T) {
	instance, _, configDir := openTestInstance(t)
	cwd := t.TempDir()
	sessionID := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	path := writeTranscriptFixture(t, configDir, cwd, sessionID)

	summaries, err := instance.ListSessions(context.Background(), cwd)
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(summaries) != 1 || summaries[0].SessionID != sessionID || summaries[0].Title != "Fix the bug quickly" || summaries[0].Cwd != cwd {
		t.Fatalf("summaries = %#v", summaries)
	}

	forked, err := instance.ForkSession(context.Background(), provider.ForkSessionInput{ProviderSessionID: sessionID})
	if err != nil {
		t.Fatalf("ForkSession: %v", err)
	}
	if forked.Summary.SessionID == sessionID || forked.Summary.SessionID == "" || forked.Summary.Title != "Fix the bug quickly (fork)" {
		t.Fatalf("fork summary = %#v", forked.Summary)
	}
	// Like the SDK's fork: new session and message ids with the chain kept,
	// so the fork replays the same conversation.
	lines, err := instance.readTranscript(forked.Summary.SessionID)
	if err != nil {
		t.Fatalf("read forked transcript: %v", err)
	}
	uuids := map[string]bool{}
	for _, line := range lines {
		if line.SessionID != forked.Summary.SessionID {
			t.Fatalf("forked line keeps old session id: %#v", line.SessionID)
		}
		if line.UUID != "" {
			uuids[line.UUID] = true
		}
		if line.ParentUUID != "" && !uuids[line.ParentUUID] {
			t.Fatalf("forked line %q has parent %q outside the fork", line.UUID, line.ParentUUID)
		}
		if line.UUID == "u1" || line.UUID == "a3" {
			t.Fatalf("forked line keeps source uuid %q", line.UUID)
		}
	}
	original, _ := instance.readTranscript(sessionID)
	replayedSource := replayEventsFromTranscript("t", original)
	replayedFork := replayEventsFromTranscript("t", lines)
	if len(replayedFork) != len(replayedSource) {
		t.Fatalf("fork replays %d events, source %d", len(replayedFork), len(replayedSource))
	}

	// A maiD rename names the session the way /rename does.
	if err := instance.RenameSession(context.Background(), provider.RenameSessionInput{ProviderSessionID: sessionID, Title: "Renamed in maiD"}); err != nil {
		t.Fatalf("RenameSession: %v", err)
	}
	if title, _ := transcriptSummary(path); title != "Renamed in maiD" {
		t.Fatalf("title after rename = %q", title)
	}

	if err := instance.DeleteSession(context.Background(), sessionID); err != nil {
		t.Fatalf("DeleteSession: %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("transcript still exists: %v", err)
	}
}
