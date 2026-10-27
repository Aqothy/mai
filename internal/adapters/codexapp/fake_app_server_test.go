package codexapp

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
)

const fakeAppServerEnvironment = "MAID_CODEXAPP_FAKE_SERVER"

func TestCodexAppServerHelperProcess(t *testing.T) {
	if os.Getenv(fakeAppServerEnvironment) != "1" {
		return
	}
	scenario := "lifecycle"
	if separator := indexOf(os.Args, "--"); separator >= 0 && separator+1 < len(os.Args) {
		scenario = os.Args[separator+1]
	}
	if err := runFakeAppServer(scenario); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	os.Exit(0)
}

func indexOf(values []string, target string) int {
	for index, value := range values {
		if value == target {
			return index
		}
	}
	return -1
}

type fakeWireMessage map[string]json.RawMessage

func runFakeAppServer(scenario string) error {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 64*1024), maxMessageBytes)
	encoder := json.NewEncoder(os.Stdout)

	initialize, err := readFakeMessage(scanner)
	if err != nil {
		return err
	}
	if err := validateInitialize(initialize); err != nil {
		return err
	}
	if err := writeFakeResult(encoder, initialize["id"], map[string]any{
		"userAgent":      "codex-test",
		"codexHome":      "/tmp/codex-home",
		"platformFamily": "unix",
		"platformOs":     "macos",
	}); err != nil {
		return err
	}
	initialized, err := readFakeMessage(scanner)
	if err != nil {
		return err
	}
	if fakeMethod(initialized) != "initialized" || hasFakeField(initialized, "id") || hasFakeField(initialized, "params") {
		return fmt.Errorf("invalid initialized notification: %s", fakeMessageJSON(initialized))
	}

	loggedIn := false
	interrupted := false
	turnStarted := false
	var goal map[string]any
	if scenario == "goal-resume" {
		goal = map[string]any{"threadId": "native-thread", "objective": "carry on", "status": "budgetLimited", "tokenBudget": 100, "tokensUsed": 150, "timeUsedSeconds": 60, "createdAt": 1, "updatedAt": 1}
	}
	for scanner.Scan() {
		message, err := decodeFakeMessage(scanner.Bytes())
		if err != nil {
			return err
		}
		method := fakeMethod(message)
		effort := "medium"
		if strings.HasPrefix(scenario, "reasoning-") {
			if scenario == "reasoning-low" {
				effort = "low"
			}
			var params struct {
				Config map[string]any `json:"config"`
				Effort string         `json:"effort"`
			}
			if err := decodeFakeParams(message, &params); err != nil {
				return err
			}
			switch method {
			case "thread/start", "thread/resume":
				if scenario == "reasoning-low" && params.Config["model_reasoning_effort"] != effort || scenario == "reasoning-default" && len(params.Config) != 0 {
					return fmt.Errorf("invalid reasoning override: %s", fakeMessageJSON(message))
				}
			case "turn/start":
				if params.Effort != effort {
					return fmt.Errorf("turn lost reasoning selection: %s", fakeMessageJSON(message))
				}
			}
		}
		switch method {
		case "config/read":
			if err := writeFakeResult(encoder, message["id"], map[string]any{
				"config":  map[string]any{"approval_policy": "on-request", "sandbox_mode": "workspace-write", "model_reasoning_summary": nil},
				"origins": map[string]any{}, "layers": nil,
			}); err != nil {
				return err
			}
		case "account/read":
			var params struct {
				RefreshToken bool `json:"refreshToken"`
			}
			if err := decodeFakeParams(message, &params); err != nil || params.RefreshToken {
				return fmt.Errorf("invalid account/read params: %s", fakeMessageJSON(message))
			}
			var account any
			if loggedIn {
				account = map[string]any{"type": "apiKey"}
			}
			if err := writeFakeResult(encoder, message["id"], map[string]any{"account": account, "requiresOpenaiAuth": true}); err != nil {
				return err
			}
		case "model/list":
			var catalogDefaultTier any
			if scenario == "catalog-priority-default" {
				catalogDefaultTier = "priority"
			}
			if err := writeFakeResult(encoder, message["id"], map[string]any{
				"data": []any{map[string]any{
					"id": "gpt-test", "model": "gpt-test", "displayName": "GPT Test", "isDefault": true,
					"defaultReasoningEffort":    "medium",
					"supportedReasoningEfforts": []any{map[string]any{"reasoningEffort": "low"}, map[string]any{"reasoningEffort": "medium"}},
					"serviceTiers": []any{
						map[string]any{"id": "priority", "name": "Fast", "description": "Fast queue"},
					},
					"defaultServiceTier": catalogDefaultTier,
				}},
				"nextCursor": nil,
			}); err != nil {
				return err
			}
		case "skills/list":
			var params struct {
				Cwds []string `json:"cwds"`
			}
			if err := decodeFakeParams(message, &params); err != nil || len(params.Cwds) != 1 {
				return fmt.Errorf("invalid skills/list params: %s", fakeMessageJSON(message))
			}
			if scenario == "skills-error" {
				if err := writeFakeError(encoder, message["id"], -32000, "skills unavailable"); err != nil {
					return err
				}
				continue
			}
			if err := writeFakeResult(encoder, message["id"], map[string]any{"data": []any{map[string]any{
				"cwd": params.Cwds[0],
				"skills": []any{map[string]any{
					"name": "review", "description": "Review the current changes", "shortDescription": "Review changes",
					"path": "/skills/review", "scope": "user", "enabled": true,
				}},
			}}}); err != nil {
				return err
			}
		case "account/login/start":
			var params map[string]any
			if err := decodeFakeParams(message, &params); err != nil {
				return err
			}
			loginType, _ := params["type"].(string)
			if scenario == "bad-auth-union" {
				if err := writeFakeResult(encoder, message["id"], map[string]any{"type": "chatgptDeviceCode", "loginId": "wrong", "verificationUrl": "https://example.test/device", "userCode": "WRONG"}); err != nil {
					return err
				}
				continue
			}
			switch loginType {
			case "chatgpt":
				if params["appBrand"] != "codex" || params["useHostedLoginSuccessPage"] != true {
					return fmt.Errorf("invalid chatgpt login params: %s", fakeMessageJSON(message))
				}
				err = writeFakeResult(encoder, message["id"], map[string]any{"type": "chatgpt", "loginId": "browser-login", "authUrl": "https://example.test/auth"})
			case "chatgptDeviceCode":
				err = writeFakeResult(encoder, message["id"], map[string]any{"type": "chatgptDeviceCode", "loginId": "device-login", "verificationUrl": "https://example.test/device", "userCode": "ABCD-EFGH"})
			case "apiKey":
				if params["apiKey"] != "sk-test" {
					return fmt.Errorf("invalid API key login params: %s", fakeMessageJSON(message))
				}
				loggedIn = true
				err = writeFakeResult(encoder, message["id"], map[string]any{"type": "apiKey"})
			default:
				return fmt.Errorf("unexpected login type %q", loginType)
			}
			if err != nil {
				return err
			}
		case "account/login/cancel":
			// A new sign-in cancels the one before it.
			var params struct {
				LoginID string `json:"loginId"`
			}
			if err := decodeFakeParams(message, &params); err != nil || params.LoginID == "" {
				return fmt.Errorf("invalid account/login/cancel params: %s", fakeMessageJSON(message))
			}
			if err := writeFakeResult(encoder, message["id"], map[string]any{"status": "canceled"}); err != nil {
				return err
			}
		case "account/logout":
			if hasFakeField(message, "params") {
				return fmt.Errorf("account/logout must omit params: %s", fakeMessageJSON(message))
			}
			loggedIn = false
			if err := writeFakeResult(encoder, message["id"], map[string]any{}); err != nil {
				return err
			}
		case "thread/start":
			var params struct {
				Cwd         string `json:"cwd"`
				ServiceTier string `json:"serviceTier"`
			}
			if err := decodeFakeParams(message, &params); err != nil || params.Cwd != "/tmp" || scenario == "service-tier" && params.ServiceTier != "priority" {
				return fmt.Errorf("invalid thread/start params: %s", fakeMessageJSON(message))
			}
			response := fakeThreadResponse("native-thread")
			response["reasoningEffort"] = effort
			if scenario == "service-tier" {
				response["serviceTier"] = "priority"
			}
			if scenario == "permissions" {
				var permissions struct {
					ApprovalPolicy string `json:"approvalPolicy"`
					Sandbox        string `json:"sandbox"`
				}
				if err := decodeFakeParams(message, &permissions); err != nil || permissions.ApprovalPolicy != "never" || permissions.Sandbox != "danger-full-access" {
					return fmt.Errorf("thread/start lost the permissions preset: %s", fakeMessageJSON(message))
				}
				response["approvalPolicy"] = "never"
				response["sandbox"] = map[string]any{"type": "dangerFullAccess"}
			}
			if err := writeFakeResult(encoder, message["id"], response); err != nil {
				return err
			}
		case "thread/resume":
			var params struct {
				ThreadID     string `json:"threadId"`
				ExcludeTurns bool   `json:"excludeTurns"`
			}
			if err := decodeFakeParams(message, &params); err != nil || params.ThreadID != "native-thread" || !params.ExcludeTurns {
				return fmt.Errorf("invalid thread/resume params: %s", fakeMessageJSON(message))
			}
			if scenario == "resume-notification" {
				if err := writeFakeNotification(encoder, "thread/name/updated", map[string]any{"threadId": "native-thread", "threadName": "Resumed before response"}); err != nil {
					return err
				}
			}
			responseID := "native-thread"
			if scenario == "resume-wrong-identity" {
				responseID = "different-thread"
			}
			response := fakeThreadResponse(responseID)
			response["reasoningEffort"] = effort
			if err := writeFakeResult(encoder, message["id"], response); err != nil {
				return err
			}
		case "turn/start":
			if scenario == "exit-before-turn" {
				return nil
			}
			if scenario == "handoff" && strings.Contains(fakeMessageJSON(message), "too long") {
				if err := writeFakeError(encoder, message["id"], -32600, "input too large"); err != nil {
					return err
				}
				continue
			}
			if scenario == "handoff" {
				// The input joins the goal's running turn, which replies and
				// ends; the goal then continues with another.
				if err := validateTurnStart(message, "client-local-turn-hello"); err != nil {
					return err
				}
				if err := writeFakeResult(encoder, message["id"], map[string]any{"turn": fakeTurn("goal-turn", "inProgress")}); err != nil {
					return err
				}
				for _, notification := range []struct {
					method string
					params map[string]any
				}{
					{"item/completed", map[string]any{"threadId": "native-thread", "turnId": "goal-turn", "item": map[string]any{"type": "agentMessage", "id": "reply", "text": "hi"}}},
					{"turn/completed", map[string]any{"threadId": "native-thread", "turn": fakeTurn("goal-turn", "completed")}},
					{"turn/started", map[string]any{"threadId": "native-thread", "turn": fakeTurn("goal-turn-2", "inProgress")}},
				} {
					if err := writeFakeNotification(encoder, notification.method, notification.params); err != nil {
						return err
					}
				}
				continue
			}
			clientID := "local-turn"
			if scenario == "message-identities" {
				clientID = "client-start"
			}
			if err := validateTurnStart(message, clientID); err != nil {
				return err
			}
			var turnPermissions struct {
				ApprovalPolicy string `json:"approvalPolicy"`
				SandboxPolicy  *struct {
					Type string `json:"type"`
				} `json:"sandboxPolicy"`
			}
			if err := decodeFakeParams(message, &turnPermissions); err != nil {
				return err
			}
			// A preset picked mid-thread rides the next turn/start only.
			wantPolicy, wantSandbox := "", ""
			if scenario == "permissions" && !turnStarted {
				wantPolicy, wantSandbox = "on-request", "readOnly"
			}
			gotSandbox := ""
			if turnPermissions.SandboxPolicy != nil {
				gotSandbox = turnPermissions.SandboxPolicy.Type
			}
			if turnPermissions.ApprovalPolicy != wantPolicy || gotSandbox != wantSandbox {
				return fmt.Errorf("turn/start permissions = %s, want %q/%q", fakeMessageJSON(message), wantPolicy, wantSandbox)
			}
			turnStarted = true
			if scenario == "service-tier" {
				var params struct {
					ServiceTier string `json:"serviceTier"`
				}
				if err := decodeFakeParams(message, &params); err != nil || params.ServiceTier != "priority" {
					return fmt.Errorf("invalid tiered turn/start params: %s", fakeMessageJSON(message))
				}
			}
			if scenario == "complete-and-exit" {
				if err := writeFakeNotification(encoder, "turn/started", map[string]any{"threadId": "native-thread", "turn": fakeTurn("native-turn", "inProgress")}); err != nil {
					return err
				}
				completed := fakeTurn("native-turn", "completed")
				completed["completedAt"] = 2.0
				if err := writeFakeNotification(encoder, "turn/completed", map[string]any{"threadId": "native-thread", "turn": completed}); err != nil {
					return err
				}
			}
			if err := writeFakeResult(encoder, message["id"], map[string]any{"turn": fakeTurn("native-turn", "inProgress")}); err != nil {
				return err
			}
			if scenario == "complete-and-exit" {
				return nil
			}
			if err := writeFakeNotification(encoder, "thread/name/updated", map[string]any{"threadId": "native-thread", "threadName": "Protocol title"}); err != nil {
				return err
			}
			if scenario == "approval" || scenario == "approval-amendment" || scenario == "approval-stop" || scenario == "server-resolved" || scenario == "exit-with-approval" {
				if err := writeFakeRequest(encoder, json.RawMessage("77"), "item/commandExecution/requestApproval", map[string]any{
					"threadId": "native-thread", "turnId": "native-turn", "itemId": "command-1", "startedAtMs": 1,
					"approvalId": "approval-1", "reason": "needs approval", "command": "echo hello", "cwd": "/tmp", "environmentId": nil,
					"proposedExecpolicyAmendment": []string{"echo", "hello"},
				}); err != nil {
					return err
				}
				if scenario == "server-resolved" {
					if err := writeFakeNotification(encoder, "serverRequest/resolved", map[string]any{"threadId": "native-thread", "requestId": 77}); err != nil {
						return err
					}
				}
				if scenario == "exit-with-approval" {
					return nil
				}
			}
			if scenario == "turn-failure" {
				for _, notification := range []struct {
					method string
					params map[string]any
				}{
					{"error", map[string]any{"threadId": "native-thread", "turnId": "native-turn", "willRetry": true, "error": map[string]any{"message": "Reconnecting 1/5"}}},
					{"model/rerouted", map[string]any{"threadId": "native-thread", "turnId": "native-turn", "fromModel": "gpt-test", "toModel": "gpt-safe", "reason": "highRiskCyberActivity"}},
					{"error", map[string]any{"threadId": "native-thread", "turnId": "native-turn", "willRetry": false, "error": map[string]any{"message": "boom"}}},
				} {
					if err := writeFakeNotification(encoder, notification.method, notification.params); err != nil {
						return err
					}
				}
				failed := fakeTurn("native-turn", "failed")
				failed["error"] = map[string]any{"message": "boom"}
				if err := writeFakeNotification(encoder, "turn/completed", map[string]any{"threadId": "native-thread", "turn": failed}); err != nil {
					return err
				}
			}
			if scenario == "permissions-request" {
				if err := writeFakeNotification(encoder, "thread/tokenUsage/updated", map[string]any{
					"threadId": "native-thread", "turnId": "native-turn",
					"tokenUsage": map[string]any{
						"total":              map[string]any{"totalTokens": 900000, "inputTokens": 0, "cachedInputTokens": 0, "cacheWriteInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0},
						"last":               map[string]any{"totalTokens": 1200, "inputTokens": 0, "cachedInputTokens": 0, "cacheWriteInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0},
						"modelContextWindow": 200000,
					},
				}); err != nil {
					return err
				}
				if err := writeFakeRequest(encoder, json.RawMessage("79"), "item/permissions/requestApproval", map[string]any{
					"threadId": "native-thread", "turnId": "native-turn", "itemId": "command-2", "environmentId": nil, "startedAtMs": 1,
					"cwd": "/tmp", "reason": nil,
					"permissions": map[string]any{"network": map[string]any{"enabled": true}, "fileSystem": nil},
				}); err != nil {
					return err
				}
			}
			if scenario == "mcp-tool-approval" {
				// Codex's MCP tool approval: a form asking for nothing, with
				// its approval kind and remember options only in _meta.
				if err := writeFakeRequest(encoder, json.RawMessage("76"), "mcpServer/elicitation/request", map[string]any{
					"threadId": "native-thread", "turnId": "native-turn", "serverName": "docs", "mode": "form",
					"message":         `Allow the docs MCP server to run tool "search"?`,
					"_meta":           map[string]any{"codex_approval_kind": "mcp_tool_call", "persist": []string{"session", "always"}},
					"requestedSchema": map[string]any{"type": "object", "properties": map[string]any{}},
				}); err != nil {
					return err
				}
			}
			if scenario == "elicitation" {
				if err := writeFakeRequest(encoder, json.RawMessage("78"), "mcpServer/elicitation/request", map[string]any{
					"threadId": "native-thread", "turnId": "native-turn", "serverName": "codex_apps", "mode": "form",
					"message": "Allow this request?", "_meta": nil,
					"requestedSchema": map[string]any{"type": "object", "required": []string{"confirmed"}, "properties": map[string]any{"confirmed": map[string]any{"type": "boolean"}}},
				}); err != nil {
					return err
				}
			}
		case "qa/malformed":
			if _, err := fmt.Fprintln(os.Stdout, "{not-json}"); err != nil {
				return err
			}
		case "turn/steer":
			if scenario == "steer-race" {
				// The turn ended at Codex before its turn/completed was sent,
				// or a review runs that can't take input.
				var params struct {
					Input []struct {
						Text string `json:"text"`
					} `json:"input"`
				}
				if err := decodeFakeParams(message, &params); err != nil || len(params.Input) != 1 {
					return fmt.Errorf("invalid turn/steer params: %s", fakeMessageJSON(message))
				}
				refusal := &rpcError{Code: -32600, Message: "no active turn to steer"}
				if params.Input[0].Text == "into a review" {
					refusal = &rpcError{Code: -32600, Message: "cannot steer a review turn", Data: json.RawMessage(`{"message":"cannot steer a review turn","codexErrorInfo":{"activeTurnNotSteerable":{"turnKind":"review"}}}`)}
				}
				if err := encoder.Encode(map[string]any{"id": message["id"], "error": refusal}); err != nil {
					return err
				}
				break
			}
			clientID := "steer-1"
			if scenario == "message-identities" {
				clientID = "client-steer"
			}
			if err := validateTurnSteer(message, clientID); err != nil {
				return err
			}
			if err := writeFakeResult(encoder, message["id"], map[string]any{"turnId": "native-turn"}); err != nil {
				return err
			}
		case "turn/interrupt":
			var params struct {
				ThreadID string `json:"threadId"`
				TurnID   string `json:"turnId"`
			}
			if err := decodeFakeParams(message, &params); err != nil || params.ThreadID != "native-thread" || params.TurnID != "native-turn" {
				return fmt.Errorf("invalid turn/interrupt params: %s", fakeMessageJSON(message))
			}
			interrupted = true
			if err := writeFakeResult(encoder, message["id"], map[string]any{}); err != nil {
				return err
			}
		case "thread/fork":
			var params struct {
				ThreadID   string `json:"threadId"`
				LastTurnID string `json:"lastTurnId"`
				Model      string `json:"model"`
				Config     struct {
					Effort string `json:"model_reasoning_effort"`
				} `json:"config"`
			}
			if err := decodeFakeParams(message, &params); err != nil || params.ThreadID != "native-thread" || params.LastTurnID != "native-earlier-turn" || params.Model != "fork-model" || params.Config.Effort != "low" {
				return fmt.Errorf("invalid thread/fork params: %s", fakeMessageJSON(message))
			}
			if err := writeFakeResult(encoder, message["id"], fakeThreadResponse("forked-thread")); err != nil {
				return err
			}
			if err := writeFakeNotification(encoder, "turn/completed", map[string]any{
				"threadId": "native-thread",
				"turn": map[string]any{
					"id": "native-turn", "items": []any{}, "status": "failed",
					"error":     map[string]any{"message": "model failed", "additionalDetails": "retry later"},
					"startedAt": 1.0, "completedAt": 2.0,
				},
			}); err != nil {
				return err
			}
		case "thread/name/set":
			var params struct {
				ThreadID string `json:"threadId"`
				Name     string `json:"name"`
			}
			if err := decodeFakeParams(message, &params); err != nil || params.ThreadID != "native-thread" || params.Name != "Renamed in maiD" {
				return fmt.Errorf("invalid thread/name/set params: %s", fakeMessageJSON(message))
			}
			if err := writeFakeResult(encoder, message["id"], map[string]any{}); err != nil {
				return err
			}
		case "thread/turns/list":
			var params struct {
				ThreadID string `json:"threadId"`
			}
			if err := decodeFakeParams(message, &params); err != nil || params.ThreadID != "native-thread" {
				return fmt.Errorf("invalid thread/turns/list params: %s", fakeMessageJSON(message))
			}
			if err := writeFakeResult(encoder, message["id"], map[string]any{"data": []any{}, "nextCursor": nil, "backwardsCursor": nil}); err != nil {
				return err
			}
		case "thread/goal/get":
			var params struct {
				ThreadID string `json:"threadId"`
			}
			if err := decodeFakeParams(message, &params); err != nil || params.ThreadID != "native-thread" {
				return fmt.Errorf("invalid thread/goal/get params: %s", fakeMessageJSON(message))
			}
			if err := writeFakeResult(encoder, message["id"], map[string]any{"goal": goal}); err != nil {
				return err
			}
		case "thread/goal/clear":
			var params struct {
				ThreadID string `json:"threadId"`
				Origin   string `json:"origin"`
			}
			if err := decodeFakeParams(message, &params); err != nil || params.ThreadID != "native-thread" || params.Origin != "user" {
				return fmt.Errorf("invalid thread/goal/clear params: %s", fakeMessageJSON(message))
			}
			cleared := goal != nil
			goal = nil
			if err := writeFakeResult(encoder, message["id"], map[string]any{"cleared": cleared}); err != nil {
				return err
			}
			if cleared {
				if err := writeFakeNotification(encoder, "thread/goal/cleared", map[string]any{"threadId": "native-thread"}); err != nil {
					return err
				}
			}
		case "thread/goal/set":
			var params struct {
				ThreadID  string  `json:"threadId"`
				Origin    string  `json:"origin"`
				Objective *string `json:"objective"`
				Status    string  `json:"status"`
			}
			if err := decodeFakeParams(message, &params); err != nil || params.ThreadID != "native-thread" || params.Origin != "user" {
				return fmt.Errorf("invalid thread/goal/set params: %s", fakeMessageJSON(message))
			}
			switch {
			case params.Objective != nil && goal != nil:
				return fmt.Errorf("a new objective updated the old goal in place: %s", fakeMessageJSON(message))
			case params.Objective != nil:
				goal = map[string]any{"threadId": "native-thread", "objective": *params.Objective, "tokenBudget": nil, "tokensUsed": 0, "timeUsedSeconds": 0, "createdAt": 1, "updatedAt": 1}
			case goal == nil:
				return fmt.Errorf("goal status set without a goal: %s", fakeMessageJSON(message))
			}
			goal["status"] = params.Status
			if err := writeFakeResult(encoder, message["id"], map[string]any{"goal": goal}); err != nil {
				return err
			}
			// Codex reports the change, then an active goal on an idle
			// thread may start a turn to work on it.
			if err := writeFakeNotification(encoder, "thread/goal/updated", map[string]any{"threadId": "native-thread", "turnId": nil, "goal": goal}); err != nil {
				return err
			}
			if params.Objective != nil && *params.Objective == "ship it" {
				if err := writeFakeNotification(encoder, "turn/started", map[string]any{"threadId": "native-thread", "turn": fakeTurn("goal-turn", "inProgress")}); err != nil {
					return err
				}
			}
			if scenario == "handoff" && params.Status == "paused" {
				// Pausing stops further turns; the running one finishes.
				if err := writeFakeNotification(encoder, "turn/completed", map[string]any{"threadId": "native-thread", "turn": fakeTurn("goal-turn-2", "completed")}); err != nil {
					return err
				}
			}
		case "thread/shellCommand":
			var params struct {
				ThreadID string `json:"threadId"`
				Command  string `json:"command"`
			}
			if err := decodeFakeParams(message, &params); err != nil || params.ThreadID != "native-thread" {
				return fmt.Errorf("invalid thread/shellCommand params: %s", fakeMessageJSON(message))
			}
			if err := writeFakeResult(encoder, message["id"], map[string]any{}); err != nil {
				return err
			}
			// A shell command joins the active turn, or runs as its own.
			turn := "shell-turn"
			switch params.Command {
			case "pwd":
				turn = "goal-turn"
			case "ls":
				if err := writeFakeNotification(encoder, "turn/started", map[string]any{"threadId": "native-thread", "turn": fakeTurn(turn, "inProgress")}); err != nil {
					return err
				}
			default:
				return fmt.Errorf("unexpected shell command: %s", fakeMessageJSON(message))
			}
			if err := writeFakeNotification(encoder, "item/started", map[string]any{"threadId": "native-thread", "turnId": turn, "item": map[string]any{
				"type": "commandExecution", "id": "shell-" + params.Command, "command": params.Command, "cwd": "/tmp", "status": "inProgress", "source": "userShell",
			}}); err != nil {
				return err
			}
			if err := writeFakeNotification(encoder, "turn/completed", map[string]any{"threadId": "native-thread", "turn": fakeTurn(turn, "completed")}); err != nil {
				return err
			}
		case "review/start":
			var params struct {
				ThreadID string            `json:"threadId"`
				Target   map[string]string `json:"target"`
				Delivery string            `json:"delivery"`
			}
			if err := decodeFakeParams(message, &params); err != nil || params.ThreadID != "native-thread" || params.Delivery != "inline" {
				return fmt.Errorf("invalid review/start params: %s", fakeMessageJSON(message))
			}
			turn := ""
			switch {
			case params.Target["type"] == "custom" && params.Target["instructions"] == "look for races":
				turn = "review-custom"
			case params.Target["type"] == "baseBranch" && params.Target["branch"] == "main":
				turn = "review-branch"
			default:
				return fmt.Errorf("unexpected review target: %s", fakeMessageJSON(message))
			}
			if err := writeFakeResult(encoder, message["id"], map[string]any{"turn": fakeTurn(turn, "inProgress"), "reviewThreadId": "native-thread"}); err != nil {
				return err
			}
			for _, method := range []string{"turn/started", "turn/completed"} {
				if err := writeFakeNotification(encoder, method, map[string]any{"threadId": "native-thread", "turn": fakeTurn(turn, "completed")}); err != nil {
					return err
				}
			}
		case "thread/compact/start":
			var params struct {
				ThreadID string `json:"threadId"`
			}
			if err := decodeFakeParams(message, &params); err != nil || params.ThreadID != "native-thread" {
				return fmt.Errorf("invalid thread/compact/start params: %s", fakeMessageJSON(message))
			}
			if err := writeFakeResult(encoder, message["id"], map[string]any{}); err != nil {
				return err
			}
			if scenario == "exit-before-turn" {
				return nil
			}
			for _, method := range []string{"turn/started", "turn/completed"} {
				if err := writeFakeNotification(encoder, method, map[string]any{"threadId": "native-thread", "turn": fakeTurn("compact-turn", "completed")}); err != nil {
					return err
				}
			}
		case "thread/unsubscribe":
			if scenario == "stop-active" && !interrupted {
				return fmt.Errorf("active thread unsubscribed before interrupt")
			}
			if err := writeFakeResult(encoder, message["id"], map[string]any{"status": "unsubscribed"}); err != nil {
				return err
			}
		case "":
			// A valid reply to a server request completes the turn, which
			// the tests wait for; an invalid one exits and fails the turn.
			if string(message["id"]) == "79" {
				if got := string(message["result"]); got != `{"permissions":{"fileSystem":null,"network":{"enabled":true}},"scope":"session"}` {
					return fmt.Errorf("invalid permissions response: %s", fakeMessageJSON(message))
				}
				if err := writeFakeTurnCompleted(encoder); err != nil {
					return err
				}
				continue
			}
			if string(message["id"]) == "76" {
				if got := string(message["result"]); got != `{"_meta":{"persist":"session"},"action":"accept","content":null}` {
					return fmt.Errorf("invalid tool approval response: %s", fakeMessageJSON(message))
				}
				if err := writeFakeTurnCompleted(encoder); err != nil {
					return err
				}
				continue
			}
			if string(message["id"]) == "78" {
				if got := string(message["result"]); got != `{"action":"accept","content":{"confirmed":true}}` {
					return fmt.Errorf("invalid elicitation response: %s", fakeMessageJSON(message))
				}
				if err := writeFakeTurnCompleted(encoder); err != nil {
					return err
				}
				continue
			}
			if string(message["id"]) == "77" && scenario == "approval-amendment" {
				if got := string(message["result"]); got != `{"decision":{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["echo","hello"]}}}` {
					return fmt.Errorf("invalid amendment response: %s", fakeMessageJSON(message))
				}
				if err := writeFakeTurnCompleted(encoder); err != nil {
					return err
				}
				continue
			}
			if string(message["id"]) == "77" {
				var result struct {
					Decision string `json:"decision"`
				}
				want := "acceptForSession"
				if scenario == "approval-stop" {
					want = "cancel"
				}
				if err := json.Unmarshal(message["result"], &result); err != nil || result.Decision != want {
					return fmt.Errorf("invalid approval response: %s", fakeMessageJSON(message))
				}
				if scenario == "approval" {
					if err := writeFakeTurnCompleted(encoder); err != nil {
						return err
					}
				}
				continue
			}
			return fmt.Errorf("unexpected response: %s", fakeMessageJSON(message))
		default:
			return fmt.Errorf("unexpected method %q: %s", method, fakeMessageJSON(message))
		}
	}
	return scanner.Err()
}

func validateInitialize(message fakeWireMessage) error {
	if fakeMethod(message) != "initialize" || hasFakeField(message, "jsonrpc") || !hasFakeField(message, "id") {
		return fmt.Errorf("invalid initialize request envelope: %s", fakeMessageJSON(message))
	}
	var params struct {
		ClientInfo struct {
			Name, Title, Version string
		} `json:"clientInfo"`
		Capabilities map[string]json.RawMessage `json:"capabilities"`
	}
	if err := decodeFakeParams(message, &params); err != nil {
		return err
	}
	if params.ClientInfo.Name != "maiD" || params.ClientInfo.Title != "maiD" || params.ClientInfo.Version == "" {
		return fmt.Errorf("invalid initialize clientInfo: %s", fakeMessageJSON(message))
	}
	for _, field := range []string{"experimentalApi", "requestAttestation"} {
		value, exists := params.Capabilities[field]
		if !exists || string(value) != "false" {
			return fmt.Errorf("initialize capability %s must be present and false: %s", field, fakeMessageJSON(message))
		}
	}
	return nil
}

func validateTurnStart(message fakeWireMessage, clientID string) error {
	var params struct {
		ThreadID            string         `json:"threadId"`
		ClientUserMessageID string         `json:"clientUserMessageId"`
		Input               []appUserInput `json:"input"`
		Summary             string         `json:"summary"`
	}
	if err := decodeFakeParams(message, &params); err != nil {
		return err
	}
	// The fake configuration leaves reasoning summaries unset.
	if params.ThreadID != "native-thread" || params.ClientUserMessageID != clientID || len(params.Input) != 1 || params.Input[0].Type != "text" || params.Input[0].Text != "hello" || params.Summary != "auto" {
		return fmt.Errorf("invalid turn/start params: %s", fakeMessageJSON(message))
	}
	return nil
}

func validateTurnSteer(message fakeWireMessage, clientID string) error {
	var params struct {
		ThreadID            string         `json:"threadId"`
		ExpectedTurnID      string         `json:"expectedTurnId"`
		ClientUserMessageID string         `json:"clientUserMessageId"`
		Input               []appUserInput `json:"input"`
	}
	if err := decodeFakeParams(message, &params); err != nil {
		return err
	}
	if params.ThreadID != "native-thread" || params.ExpectedTurnID != "native-turn" || params.ClientUserMessageID != clientID || len(params.Input) != 1 || params.Input[0].Text != "one more detail" {
		return fmt.Errorf("invalid turn/steer params: %s", fakeMessageJSON(message))
	}
	return nil
}

func fakeThreadResponse(threadID string) map[string]any {
	return map[string]any{
		"thread":          map[string]any{"id": threadID, "turns": []any{}},
		"model":           "gpt-test",
		"modelProvider":   "openai",
		"serviceTier":     nil,
		"cwd":             "/tmp",
		"reasoningEffort": "medium",
		"approvalPolicy":  "on-request",
		"sandbox":         map[string]any{"type": "workspaceWrite", "writableRoots": []any{}, "networkAccess": false},
	}
}

func fakeTurn(turnID, status string) map[string]any {
	return map[string]any{"id": turnID, "items": []any{}, "status": status, "error": nil, "startedAt": 1.0, "completedAt": nil}
}

func readFakeMessage(scanner *bufio.Scanner) (fakeWireMessage, error) {
	if !scanner.Scan() {
		if err := scanner.Err(); err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("unexpected EOF")
	}
	return decodeFakeMessage(scanner.Bytes())
}

func decodeFakeMessage(data []byte) (fakeWireMessage, error) {
	var message fakeWireMessage
	if err := json.Unmarshal(data, &message); err != nil {
		return nil, fmt.Errorf("decode client message: %w", err)
	}
	return message, nil
}

func decodeFakeParams(message fakeWireMessage, result any) error {
	params, exists := message["params"]
	if !exists {
		return fmt.Errorf("missing params: %s", fakeMessageJSON(message))
	}
	if err := json.Unmarshal(params, result); err != nil {
		return fmt.Errorf("decode params: %w", err)
	}
	return nil
}

func fakeMethod(message fakeWireMessage) string {
	var method string
	_ = json.Unmarshal(message["method"], &method)
	return method
}

func hasFakeField(message fakeWireMessage, field string) bool {
	_, exists := message[field]
	return exists
}

func fakeMessageJSON(message fakeWireMessage) string {
	data, _ := json.Marshal(message)
	return string(data)
}

func writeFakeResult(encoder *json.Encoder, id json.RawMessage, result any) error {
	return encoder.Encode(struct {
		ID     json.RawMessage `json:"id"`
		Result any             `json:"result"`
	}{ID: id, Result: result})
}

func writeFakeError(encoder *json.Encoder, id json.RawMessage, code int, message string) error {
	return encoder.Encode(struct {
		ID    json.RawMessage `json:"id"`
		Error *rpcError       `json:"error"`
	}{ID: id, Error: &rpcError{Code: code, Message: message}})
}

func writeFakeRequest(encoder *json.Encoder, id json.RawMessage, method string, params any) error {
	return encoder.Encode(struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params any             `json:"params"`
	}{ID: id, Method: method, Params: params})
}

func writeFakeTurnCompleted(encoder *json.Encoder) error {
	completed := fakeTurn("native-turn", "completed")
	completed["completedAt"] = 2.0
	return writeFakeNotification(encoder, "turn/completed", map[string]any{"threadId": "native-thread", "turn": completed})
}

func writeFakeNotification(encoder *json.Encoder, method string, params any) error {
	return encoder.Encode(struct {
		Method string `json:"method"`
		Params any    `json:"params"`
	}{Method: method, Params: params})
}
