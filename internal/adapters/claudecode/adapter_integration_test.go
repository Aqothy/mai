package claudecode

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
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
	sessionID := "fake-session"
	for index, arg := range os.Args {
		if (arg == "--session-id" || arg == "--resume") && index+1 < len(os.Args) {
			sessionID = os.Args[index+1]
		}
	}
	// One line per launch in the session cwd lets tests assert launch flags.
	if launches, err := os.OpenFile(fakeLaunchLog, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
		fmt.Fprintln(launches, strings.Join(os.Args[1:], " "))
		_ = launches.Close()
	}
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
			respond := func(payload any) {
				fakeWrite(map[string]any{"type": "control_response", "response": map[string]any{"subtype": "success", "request_id": requestID, "response": payload}})
			}
			switch subtype {
			case "initialize":
				respond(map[string]any{
					"commands": []map[string]any{{"name": "compact", "description": "Compact context", "argumentHint": "[instructions]"}},
					"models": []map[string]any{
						{"value": "default", "displayName": "Default", "description": "Recommended", "supportsEffort": true, "supportedEffortLevels": []string{"low", "high"}},
						{"value": "fake-model", "resolvedModel": "fake-model", "displayName": "Fake", "description": "Test model"},
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
			if strings.Contains(text, "SLOW") {
				slowTurn = true
				fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_start", "index": 0, "content_block": map[string]any{"type": "text", "text": ""}}})
				fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "text_delta", "text": "Working..."}}})
				continue
			}
			fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_start", "index": 0, "content_block": map[string]any{"type": "text", "text": ""}}})
			fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "text_delta", "text": "Hello "}}})
			fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "text_delta", "text": "world"}}})
			fakeWrite(map[string]any{"type": "assistant", "session_id": sessionID, "message": map[string]any{"id": "msg_1", "role": "assistant", "content": []map[string]any{{"type": "text", "text": "Hello world"}}}})
			fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_stop", "index": 0}})
			fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_start", "index": 1, "content_block": map[string]any{"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": map[string]any{}}}})
			fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_delta", "index": 1, "delta": map[string]any{"type": "input_json_delta", "partial_json": `{"command":"ec`}}})
			fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_delta", "index": 1, "delta": map[string]any{"type": "input_json_delta", "partial_json": `ho hi"}`}}})
			fakeWrite(map[string]any{"type": "stream_event", "session_id": sessionID, "event": map[string]any{"type": "content_block_stop", "index": 1}})
			fakeWrite(map[string]any{"type": "control_request", "request_id": "perm-1", "request": map[string]any{
				"subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": "toolu_1",
				"input":                  map[string]any{"command": "echo hi"},
				"permission_suggestions": []map[string]any{{"type": "addRules", "rules": []map[string]any{{"toolName": "Bash"}}, "behavior": "allow", "destination": "localSettings"}},
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
	config, err := json.Marshal(Config{Command: []string{executable}, Env: map[string]string{"CLAUDE_FAKE_CLI": "1"}, ConfigDir: configDir})
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
	caps := info.Capabilities
	if !caps.SessionList || !caps.LoadReplay || !caps.Resume || !caps.Fork || !caps.ConfigOptions || !caps.AdditionalDirectories {
		t.Fatalf("capabilities = %#v", caps)
	}
	if caps.ModelSwitch != provider.ModelSwitchInSession || !caps.PromptContent.Image || caps.PromptContent.Audio {
		t.Fatalf("capabilities = %#v", caps)
	}
	if caps.Auth || caps.Logout {
		t.Fatalf("capabilities advertise auth, but the CLI has no non-interactive login: %#v", caps)
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
	if model, ok := currentConfigString(result.Session.ConfigOptions, "model"); !ok || model != "default" {
		t.Fatalf("model option = %q %v", model, ok)
	}
	if mode, ok := currentConfigString(result.Session.ConfigOptions, "permission_mode"); !ok || mode != "default" {
		t.Fatalf("mode option = %q %v", mode, ok)
	}
	metadata := waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventThreadMetadataUpdate
	})
	if len(metadata.Payload.SlashCommands) != 1 || metadata.Payload.SlashCommands[0].Name != "compact" {
		t.Fatalf("slash commands = %#v", metadata.Payload.SlashCommands)
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

const fakeLaunchLog = "fake-cli-launches.log"

func fakeLaunches(t *testing.T, cwd string) []string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(cwd, fakeLaunchLog))
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(data)), "\n")
}

func TestEffortChangeAppliesFromTheNextTurn(t *testing.T) {
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
	// Changed while a turn runs: the running process must not be replaced.
	if err := instance.SetConfigOption(context.Background(), provider.SetConfigOptionInput{ThreadID: "thread-effort", OptionID: "effort", Value: "high"}); err != nil {
		t.Fatalf("SetConfigOption: %v", err)
	}
	if launches := fakeLaunches(t, cwd); len(launches) != 1 {
		t.Fatalf("launches during turn = %q", launches)
	}
	if err := instance.InterruptTurn(context.Background(), provider.InterruptTurnInput{ThreadID: "thread-effort", TurnID: "turn-slow"}); err != nil {
		t.Fatalf("InterruptTurn: %v", err)
	}
	waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventTurnCompleted && event.TurnID == "turn-slow"
	})
	if err := instance.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-effort", TurnID: "turn-next", Input: "next"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	launches := fakeLaunches(t, cwd)
	if len(launches) != 2 || !strings.Contains(launches[1], "--effort high") {
		t.Fatalf("launches = %q, want the next turn relaunched with --effort high", launches)
	}
}

func TestInterruptTurn(t *testing.T) {
	instance, events, _ := openTestInstance(t)
	cwd := t.TempDir()
	if _, err := instance.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-2", Cwd: cwd}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := instance.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-2", TurnID: "turn-slow", Input: "SLOW work"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventContentDelta && event.TurnID == "turn-slow"
	})
	if err := instance.InterruptTurn(context.Background(), provider.InterruptTurnInput{ThreadID: "thread-2", TurnID: "turn-slow"}); err != nil {
		t.Fatalf("InterruptTurn: %v", err)
	}
	turnDone := waitForEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventTurnCompleted && event.TurnID == "turn-slow"
	})
	if turnDone.Payload.TurnState != provider.RuntimeTurnInterrupted {
		t.Fatalf("turn completion = %#v, want interrupted", turnDone.Payload)
	}
}

func writeTranscriptFixture(t *testing.T, configDir, cwd, sessionID string) string {
	t.Helper()
	dir := filepath.Join(configDir, "projects", mungeProjectPath(cwd))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, sessionID+".jsonl")
	lines := []string{
		`{"type":"queue-operation","operation":"enqueue"}`,
		fmt.Sprintf(`{"type":"user","uuid":"u1","timestamp":"2026-08-21T10:00:00Z","sessionId":%q,"cwd":%q,"message":{"role":"user","content":"Fix the bug"}}`, sessionID, cwd),
		fmt.Sprintf(`{"type":"assistant","uuid":"a1","timestamp":"2026-08-21T10:00:05Z","sessionId":%q,"message":{"id":"msg_1","role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}`, sessionID),
		fmt.Sprintf(`{"type":"assistant","uuid":"a2","timestamp":"2026-08-21T10:00:06Z","sessionId":%q,"message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_9","name":"Bash","input":{"command":"make test"}}]}}`, sessionID),
		fmt.Sprintf(`{"type":"user","uuid":"u2","timestamp":"2026-08-21T10:00:08Z","sessionId":%q,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_9","content":"ok","is_error":false}]}}`, sessionID),
		fmt.Sprintf(`{"type":"assistant","uuid":"a3","timestamp":"2026-08-21T10:00:09Z","sessionId":%q,"message":{"id":"msg_2","role":"assistant","content":[{"type":"text","text":"Done."}]}}`, sessionID),
		fmt.Sprintf(`{"type":"ai-title","aiTitle":"Fix the bug quickly","sessionId":%q}`, sessionID),
	}
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestStartSessionReplaysTranscript(t *testing.T) {
	instance, _, configDir := openTestInstance(t)
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
	// Deterministic ids: replaying twice yields identical event ids.
	transcript, err := readTranscriptFile(filepath.Join(configDir, "projects", mungeProjectPath(cwd), sessionID+".jsonl"))
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

func TestForkSessionCopiesTranscript(t *testing.T) {
	instance, _, configDir := openTestInstance(t)
	cwd := t.TempDir()
	sessionID := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	writeTranscriptFixture(t, configDir, cwd, sessionID)
	forked, err := instance.ForkSession(context.Background(), provider.ForkSessionInput{ProviderSessionID: sessionID})
	if err != nil {
		t.Fatalf("ForkSession: %v", err)
	}
	if forked.Summary.SessionID == sessionID || forked.Summary.SessionID == "" {
		t.Fatalf("fork id = %q", forked.Summary.SessionID)
	}
	if forked.Summary.Title != "Fix the bug quickly" {
		t.Fatalf("fork title = %q", forked.Summary.Title)
	}
	lines, err := readTranscriptFile(filepath.Join(configDir, "projects", mungeProjectPath(cwd), forked.Summary.SessionID+".jsonl"))
	if err != nil {
		t.Fatalf("read forked transcript: %v", err)
	}
	for _, line := range lines {
		if line.SessionID != "" && line.SessionID != forked.Summary.SessionID {
			t.Fatalf("forked line keeps old session id: %#v", line.SessionID)
		}
	}
}

func TestListSessions(t *testing.T) {
	instance, _, configDir := openTestInstance(t)
	cwd := t.TempDir()
	sessionID := "99999999-8888-7777-6666-555555555555"
	writeTranscriptFixture(t, configDir, cwd, sessionID)
	summaries, err := instance.ListSessions(context.Background(), cwd)
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(summaries) != 1 || summaries[0].SessionID != sessionID {
		t.Fatalf("summaries = %#v", summaries)
	}
	if summaries[0].Title != "Fix the bug quickly" || summaries[0].Cwd != cwd {
		t.Fatalf("summary = %#v", summaries[0])
	}
}

func TestDeleteSessionRemovesTranscript(t *testing.T) {
	instance, _, configDir := openTestInstance(t)
	cwd := t.TempDir()
	sessionID := "12121212-3434-5656-7878-909090909090"
	path := writeTranscriptFixture(t, configDir, cwd, sessionID)
	if err := instance.DeleteSession(context.Background(), sessionID); err != nil {
		t.Fatalf("DeleteSession: %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("transcript still exists: %v", err)
	}
}
