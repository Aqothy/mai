package codexapp

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
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

func TestInstanceUsesDistinctClientMessageIDsForSteering(t *testing.T) {
	instance := openFakeInstance(t, "message-identities", func(provider.RuntimeEvent) {})
	if _, err := instance.StartSession(testContext(t), provider.StartSessionInput{ThreadID: "local-thread", Cwd: "/tmp"}); err != nil {
		t.Fatal(err)
	}
	for index, input := range []provider.SendTurnInput{
		{ThreadID: "local-thread", TurnID: "local-turn", Input: "hello", ClientMessageID: "client-start"},
		{ThreadID: "local-thread", TurnID: "local-turn", Input: "one more detail", ClientMessageID: "client-steer"},
	} {
		if err := instance.SendTurn(testContext(t), input); err != nil {
			t.Fatalf("send %d: %v", index, err)
		}
	}
}

func TestInstanceStableLifecycleWireFlow(t *testing.T) {
	events := make(chan provider.RuntimeEvent, 32)
	instance := openFakeInstance(t, "lifecycle", func(event provider.RuntimeEvent) { events <- event })

	result, err := instance.StartSession(testContext(t), provider.StartSessionInput{ThreadID: "local-thread", Cwd: "/tmp"})
	if err != nil {
		t.Fatalf("start session: %v", err)
	}
	if result.Session.ProviderSessionID != "native-thread" {
		t.Fatalf("provider session id = %q", result.Session.ProviderSessionID)
	}
	if tier, ok := currentConfigString(result.Session.ConfigOptions, "service_tier"); !ok || tier != defaultServiceTier {
		t.Fatalf("default service tier = %q, %v; options = %#v", tier, ok, result.Session.ConfigOptions)
	}
	if err := instance.SendTurn(testContext(t), provider.SendTurnInput{ThreadID: "local-thread", TurnID: "local-turn", Input: "hello"}); err != nil {
		t.Fatalf("start turn: %v", err)
	}
	if err := instance.SendTurn(testContext(t), provider.SendTurnInput{ThreadID: "local-thread", TurnID: "local-turn", Input: "one more detail"}); err != nil {
		t.Fatalf("steer turn: %v", err)
	}

	title := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventThreadMetadataUpdate
	})
	if title.Payload.Title != "Protocol title" {
		t.Fatalf("thread title = %q", title.Payload.Title)
	}

	// Codex keeps a fork loaded, so the fork request itself carries the
	// source's model and reasoning.
	fork, err := instance.ForkSession(testContext(t), provider.ForkSessionInput{
		ProviderSessionID: "native-thread",
		ModelSelection:    &provider.ModelSelection{Model: "fork-model"},
		ConfigSelections:  []provider.ConfigOptionSelection{{OptionID: "reasoning_effort", Value: "low", Category: provider.ConfigOptionCategoryThoughtLevel}},
	})
	if err != nil {
		t.Fatalf("fork session: %v", err)
	}
	if fork.Summary.SessionID != "forked-thread" {
		t.Fatalf("forked provider session id = %q", fork.Summary.SessionID)
	}
	completed := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventTurnCompleted
	})
	if completed.Payload.TurnState != provider.RuntimeTurnFailed || completed.Payload.Message != "model failed" || completed.Payload.Detail != "retry later" {
		t.Fatalf("failed turn payload = %#v", completed.Payload)
	}
	if err := instance.StopSession(testContext(t), provider.StopSessionInput{ThreadID: "local-thread"}); err != nil {
		t.Fatalf("stop session: %v", err)
	}
	if err := instance.Close(); err != nil {
		t.Fatalf("intentional close: %v", err)
	}
}

func TestResumeBindsBeforeNotificationsAndRejectsIdentityChanges(t *testing.T) {
	t.Run("notification before response", func(t *testing.T) {
		events := make(chan provider.RuntimeEvent, 8)
		instance := openFakeInstance(t, "resume-notification", func(event provider.RuntimeEvent) { events <- event })
		result, err := instance.StartSession(testContext(t), provider.StartSessionInput{
			ThreadID: "local-thread", ProviderSessionID: "native-thread", Cwd: "/tmp",
		})
		if err != nil {
			t.Fatalf("resume session: %v", err)
		}
		if result.Session.ProviderSessionID != "native-thread" {
			t.Fatalf("resumed provider session = %q", result.Session.ProviderSessionID)
		}
		title := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
			return event.Type == provider.RuntimeEventThreadMetadataUpdate
		})
		if title.ThreadID != "local-thread" || title.Payload.Title != "Resumed before response" {
			t.Fatalf("early resume notification = %#v", title)
		}
	})

	t.Run("changed identity", func(t *testing.T) {
		instance := openFakeInstance(t, "resume-wrong-identity", nil)
		if _, err := instance.StartSession(testContext(t), provider.StartSessionInput{
			ThreadID: "local-thread", ProviderSessionID: "native-thread", Cwd: "/tmp",
		}); err == nil {
			t.Fatal("resume accepted a different native thread id")
		}
		instance.mu.Lock()
		bound := instance.sessionsByLocal["local-thread"]
		instance.mu.Unlock()
		if bound != nil {
			t.Fatalf("failed resume left binding %#v", bound)
		}
	})
}

func TestStartSessionReusesLiveBinding(t *testing.T) {
	instance := openFakeInstance(t, "lifecycle", nil)
	if _, err := instance.StartSession(testContext(t), provider.StartSessionInput{ThreadID: "local-thread", Cwd: "/tmp"}); err != nil {
		t.Fatalf("start session: %v", err)
	}
	instance.mu.Lock()
	existing := instance.sessionsByLocal["local-thread"]
	existing.items["command-1"] = provider.ToolCall{Command: "echo existing"}
	instance.mu.Unlock()

	result, err := instance.StartSession(testContext(t), provider.StartSessionInput{
		ThreadID: "local-thread", ProviderSessionID: "native-thread", Cwd: "/tmp",
	})
	if err != nil {
		t.Fatalf("reuse session: %v", err)
	}
	instance.mu.Lock()
	reused := instance.sessionsByLocal["local-thread"]
	tool := reused.items["command-1"]
	instance.mu.Unlock()
	if reused != existing || tool.Command != "echo existing" || result.Session.ProviderSessionID != "native-thread" {
		t.Fatalf("live binding was replaced: reused=%t tool=%#v result=%#v", reused == existing, tool, result.Session)
	}
}

func TestStopSessionInterruptsActiveTurnBeforeUnsubscribe(t *testing.T) {
	instance := openFakeInstance(t, "stop-active", nil)
	if _, err := instance.StartSession(testContext(t), provider.StartSessionInput{ThreadID: "local-thread", Cwd: "/tmp"}); err != nil {
		t.Fatalf("start session: %v", err)
	}
	if err := instance.SendTurn(testContext(t), provider.SendTurnInput{ThreadID: "local-thread", TurnID: "local-turn", Input: "hello"}); err != nil {
		t.Fatalf("start turn: %v", err)
	}
	if err := instance.StopSession(testContext(t), provider.StopSessionInput{ThreadID: "local-thread"}); err != nil {
		t.Fatalf("stop active session: %v", err)
	}
}

func TestServiceTierFlowsThroughSessionAndTurnRequests(t *testing.T) {
	instance := openFakeInstance(t, "service-tier", nil)
	result, err := instance.StartSession(testContext(t), provider.StartSessionInput{
		ThreadID: "local-thread", Cwd: "/tmp",
		ConfigSelections: []provider.ConfigOptionSelection{{OptionID: "service_tier", Value: "priority"}},
	})
	if err != nil {
		t.Fatalf("start tiered session: %v", err)
	}
	tier, ok := currentConfigString(result.Session.ConfigOptions, "service_tier")
	if !ok || tier != "priority" {
		t.Fatalf("session service tier = %q, %v; options = %#v", tier, ok, result.Session.ConfigOptions)
	}
	if err := instance.SendTurn(testContext(t), provider.SendTurnInput{ThreadID: "local-thread", TurnID: "local-turn", Input: "hello"}); err != nil {
		t.Fatalf("start tiered turn: %v", err)
	}
}

func TestReasoningEffortFlowsThroughNewAndResumedSessions(t *testing.T) {
	for _, nativeID := range []string{"", "native-thread"} {
		for _, selected := range []bool{false, true} {
			t.Run(fmt.Sprintf("native=%s/selected=%t", nativeID, selected), func(t *testing.T) {
				scenario, want := "reasoning-default", "medium"
				input := provider.StartSessionInput{ThreadID: "local-thread", ProviderSessionID: nativeID, Cwd: "/tmp"}
				if selected {
					scenario, want = "reasoning-low", "low"
					input.ConfigSelections = []provider.ConfigOptionSelection{{OptionID: "reasoning_effort", Value: want}}
				}
				instance := openFakeInstance(t, scenario, nil)
				result, err := instance.StartSession(testContext(t), input)
				if err != nil {
					t.Fatalf("start session: %v", err)
				}
				if got, ok := currentConfigString(result.Session.ConfigOptions, "reasoning_effort"); !ok || got != want {
					t.Fatalf("session effort = %q, %v; want %q", got, ok, want)
				}
				if err := instance.SendTurn(testContext(t), provider.SendTurnInput{ThreadID: "local-thread", TurnID: "local-turn", Input: "hello"}); err != nil {
					t.Fatalf("start turn: %v", err)
				}
			})
		}
	}
}

func TestAuthoritativeNullServiceTierRemainsStandard(t *testing.T) {
	instance := openFakeInstance(t, "catalog-priority-default", nil)
	result, err := instance.StartSession(testContext(t), provider.StartSessionInput{
		ThreadID: "local-thread", ProviderSessionID: "native-thread", Cwd: "/tmp",
	})
	if err != nil {
		t.Fatalf("resume session: %v", err)
	}
	tier, ok := currentConfigString(result.Session.ConfigOptions, "service_tier")
	if !ok || tier != defaultServiceTier {
		t.Fatalf("authoritative null tier = %q, %v; options = %#v", tier, ok, result.Session.ConfigOptions)
	}
	instance.mu.Lock()
	storedTier := instance.sessionsByLocal["local-thread"].serviceTier
	instance.mu.Unlock()
	if storedTier != defaultServiceTier {
		t.Fatalf("stored service tier = %q", storedTier)
	}
}

func TestInstanceAccountLoginUnionsAndParameterlessLogout(t *testing.T) {
	instance := openFakeInstance(t, "auth", nil)

	browser, err := instance.AuthenticateWithInput(testContext(t), provider.AuthenticateInput{MethodID: authMethodChatGPT})
	if err != nil {
		t.Fatalf("browser login: %v", err)
	}
	if browser.Challenge == nil || browser.Challenge.Kind != "browser" || browser.Challenge.URL != "https://example.test/auth" {
		t.Fatalf("browser challenge = %#v", browser.Challenge)
	}

	device, err := instance.AuthenticateWithInput(testContext(t), provider.AuthenticateInput{MethodID: authMethodDevice})
	if err != nil {
		t.Fatalf("device login: %v", err)
	}
	if device.Challenge == nil || device.Challenge.Kind != "device-code" || device.Challenge.UserCode != "ABCD-EFGH" {
		t.Fatalf("device challenge = %#v", device.Challenge)
	}

	apiKey, err := instance.AuthenticateWithInput(testContext(t), provider.AuthenticateInput{MethodID: authMethodAPIKey, Secret: "sk-test"})
	if err != nil {
		t.Fatalf("API key login: %v", err)
	}
	if apiKey.Instance.Auth.Status != provider.AuthStatusAuthenticated {
		t.Fatalf("API key auth status = %q", apiKey.Instance.Auth.Status)
	}
	loggedOut, err := instance.Logout(testContext(t))
	if err != nil {
		t.Fatalf("logout: %v", err)
	}
	if loggedOut.Auth.Status != provider.AuthStatusUnauthenticated {
		t.Fatalf("logout auth status = %q", loggedOut.Auth.Status)
	}
}

func TestInstanceRejectsMismatchedAccountLoginUnion(t *testing.T) {
	instance := openFakeInstance(t, "bad-auth-union", nil)
	_, err := instance.AuthenticateWithInput(testContext(t), provider.AuthenticateInput{MethodID: authMethodChatGPT})
	if err == nil || !strings.Contains(err.Error(), "returned type") {
		t.Fatalf("mismatched login error = %v", err)
	}
}

func TestOptionsSessionIncludesCwdScopedSkills(t *testing.T) {
	instance := openFakeInstance(t, "options", nil)
	opened, err := instance.OpenOptionsSession(testContext(t), "/workspace", provider.OptionsSessionCallbacks{})
	if err != nil {
		t.Fatalf("open options session: %v", err)
	}
	if len(opened.Skills) != 1 {
		t.Fatalf("options skills = %#v", opened.Skills)
	}
	skill := opened.Skills[0]
	if skill.Name != "review" || skill.Path != "/skills/review" || skill.ShortDescription != "Review changes" || !skill.Enabled {
		t.Fatalf("options skill = %#v", skill)
	}
}

func TestOptionsSessionRecoversWhenSkillsListFails(t *testing.T) {
	instance := openFakeInstance(t, "skills-error", nil)
	opened, err := instance.OpenOptionsSession(testContext(t), "/workspace", provider.OptionsSessionCallbacks{})
	if err != nil {
		t.Fatalf("open options session: %v", err)
	}
	if opened.Handle == "" {
		t.Fatal("recoverable skills/list failure returned an empty options handle")
	}
	if len(opened.ConfigOptions) == 0 || opened.ConfigOptions[0].CurrentValue != "gpt-test" {
		t.Fatalf("config options after failed skills/list = %#v", opened.ConfigOptions)
	}
	if len(opened.Skills) != 0 {
		t.Fatalf("skills after failed skills/list = %#v", opened.Skills)
	}
}

func TestInstanceApprovalResponseUsesStableDecision(t *testing.T) {
	events := make(chan provider.RuntimeEvent, 32)
	instance := openFakeInstance(t, "approval", func(event provider.RuntimeEvent) { events <- event })
	startFakeTurn(t, instance)

	opened := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventRequestOpened
	})
	if opened.RequestID != "approval-1" || opened.Payload.RequestType != provider.RuntimeRequestCommandExecution {
		t.Fatalf("approval opened = %#v", opened)
	}
	// Options use the provider-neutral (ACP) permission kinds.
	kinds := map[string]string{}
	for _, option := range opened.Payload.Options {
		kinds[option.ID] = option.Kind
	}
	if kinds["accept"] != "allow_once" || kinds["acceptForSession"] != "allow_always" || kinds["decline"] != "reject_once" {
		t.Fatalf("approval option kinds = %v", kinds)
	}
	if err := instance.RespondToRequest(testContext(t), provider.RespondToRequestInput{ThreadID: "local-thread", RequestID: opened.RequestID, OptionID: "acceptForSession"}); err != nil {
		t.Fatalf("respond to approval: %v", err)
	}
	resolved := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventRequestResolved
	})
	if resolved.Payload.Decision != provider.ApprovalDecisionAcceptForSession || resolved.Payload.Cancelled {
		t.Fatalf("approval resolved payload = %#v", resolved.Payload)
	}
}

func TestStopSessionResolvesPendingApproval(t *testing.T) {
	events := make(chan provider.RuntimeEvent, 32)
	instance := openFakeInstance(t, "approval-stop", func(event provider.RuntimeEvent) { events <- event })
	startFakeTurn(t, instance)

	opened := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventRequestOpened
	})
	if err := instance.StopSession(testContext(t), provider.StopSessionInput{ThreadID: "local-thread"}); err != nil {
		t.Fatalf("stop session: %v", err)
	}
	resolved := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventRequestResolved && event.RequestID == opened.RequestID
	})
	if !resolved.Payload.Cancelled || resolved.Payload.Decision != provider.ApprovalDecisionCancel {
		t.Fatalf("stop resolution = %#v", resolved.Payload)
	}
}

func TestInstanceServerResolvedNotificationClearsApproval(t *testing.T) {
	events := make(chan provider.RuntimeEvent, 32)
	instance := openFakeInstance(t, "server-resolved", func(event provider.RuntimeEvent) { events <- event })
	startFakeTurn(t, instance)

	opened := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventRequestOpened
	})
	resolved := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventRequestResolved && event.RequestID == opened.RequestID
	})
	if !resolved.Payload.Cancelled {
		t.Fatalf("server-resolved approval was not marked cancelled: %#v", resolved.Payload)
	}
	if err := instance.RespondToRequest(testContext(t), provider.RespondToRequestInput{ThreadID: "local-thread", RequestID: opened.RequestID, Decision: provider.ApprovalDecisionAccept}); err == nil {
		t.Fatal("responding to a server-resolved approval unexpectedly succeeded")
	}
}

func TestUnexpectedProcessExitResolvesPendingApproval(t *testing.T) {
	events := make(chan provider.RuntimeEvent, 32)
	instance := openFakeInstance(t, "exit-with-approval", func(event provider.RuntimeEvent) { events <- event })
	startFakeTurn(t, instance)

	opened := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventRequestOpened
	})
	resolved := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventRequestResolved && event.RequestID == opened.RequestID
	})
	if !resolved.Payload.Cancelled {
		t.Fatalf("process-exit resolution = %#v", resolved.Payload)
	}
}

func TestProcessExitSettlesActiveTurn(t *testing.T) {
	for _, intentional := range []bool{false, true} {
		t.Run(fmt.Sprintf("intentional=%v", intentional), func(t *testing.T) {
			events := make(chan provider.RuntimeEvent, 32)
			instance := openFakeInstance(t, "lifecycle", func(event provider.RuntimeEvent) { events <- event })
			startFakeTurn(t, instance)
			if intentional {
				if err := instance.Close(); err != nil {
					t.Fatal(err)
				}
			} else if err := instance.cmd.Process.Kill(); err != nil {
				t.Fatal(err)
			}
			completed := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
				return event.Type == provider.RuntimeEventTurnCompleted
			})
			want := provider.RuntimeTurnFailed
			if intentional {
				want = provider.RuntimeTurnCancelled
			}
			if completed.ThreadID != "local-thread" || completed.TurnID != "local-turn" || completed.Payload.TurnState != want {
				t.Fatalf("exit completion = %#v", completed)
			}
			if !intentional && !strings.Contains(completed.Payload.Message, "Codex") {
				t.Fatalf("missing actionable failure: %#v", completed.Payload)
			}
			select {
			case <-instance.processDone:
			case <-testContext(t).Done():
				t.Fatal("provider did not finish cleanup")
			}
			for len(events) > 0 {
				if event := <-events; event.Type == provider.RuntimeEventTurnCompleted {
					t.Fatalf("duplicate exit completion: %#v", event)
				}
			}
		})
	}
}

func TestMalformedTransportSettlesTurnAndStopsProcess(t *testing.T) {
	events := make(chan provider.RuntimeEvent, 32)
	instance := openFakeInstance(t, "lifecycle", func(event provider.RuntimeEvent) { events <- event })
	startFakeTurn(t, instance)
	if err := instance.rpc.notify("qa/malformed", nil); err != nil {
		t.Fatal(err)
	}
	completed := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventTurnCompleted
	})
	if completed.TurnID != "local-turn" || completed.Payload.TurnState != provider.RuntimeTurnFailed || !strings.Contains(completed.Payload.Message, "decode Codex app-server message") {
		t.Fatalf("malformed transport outcome = %#v", completed)
	}
	select {
	case <-instance.processDone:
	case <-testContext(t).Done():
		t.Fatal("unusable app-server process was left running")
	}
	if err := instance.emitTurnStarted("native-thread", "unacknowledged-turn"); err == nil {
		t.Fatal("late turn/start response reactivated a closed transport")
	}
}

// The turn completes before its turn/start response arrives. Reactivating it
// from that late response would make the exit emit a second, failed completion.
func TestCompletedTurnIsNotFailedOnProcessExit(t *testing.T) {
	events := make(chan provider.RuntimeEvent, 32)
	instance := openFakeInstance(t, "complete-and-exit", func(event provider.RuntimeEvent) { events <- event })
	startFakeTurn(t, instance)
	select {
	case <-instance.processDone:
	case <-testContext(t).Done():
		t.Fatal("provider did not exit")
	}
	var completions []provider.RuntimeEvent
	for len(events) > 0 {
		if event := <-events; event.Type == provider.RuntimeEventTurnCompleted {
			completions = append(completions, event)
		}
	}
	if len(completions) != 1 || completions[0].Payload.TurnState != provider.RuntimeTurnCompleted {
		t.Fatalf("completed turn was lost or failed again on exit: %#v", completions)
	}
}

func openFakeInstance(t *testing.T, scenario string, emit provider.RuntimeEventListener) *Instance {
	t.Helper()
	config, err := json.Marshal(Config{
		Command: []string{os.Args[0], "-test.run=^TestCodexAppServerHelperProcess$", "--", scenario},
		Env:     map[string]string{fakeAppServerEnvironment: "1"},
	})
	if err != nil {
		t.Fatal(err)
	}
	instance, err := OpenInstance(testContext(t), provider.InstanceSpec{
		InstanceID: "codex-test",
		Name:       "Codex Test",
		Driver:     DriverKind,
		Config:     config,
	}, emit)
	if err != nil {
		t.Fatalf("open fake app-server: %v", err)
	}
	t.Cleanup(func() { _ = instance.Close() })
	return instance
}

func startFakeTurn(t *testing.T, instance *Instance) {
	t.Helper()
	if _, err := instance.StartSession(testContext(t), provider.StartSessionInput{ThreadID: "local-thread", Cwd: "/tmp"}); err != nil {
		t.Fatalf("start fake session: %v", err)
	}
	if err := instance.SendTurn(testContext(t), provider.SendTurnInput{ThreadID: "local-thread", TurnID: "local-turn", Input: "hello"}); err != nil {
		t.Fatalf("start fake turn: %v", err)
	}
}

func testContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func waitForRuntimeEvent(t *testing.T, events <-chan provider.RuntimeEvent, match func(provider.RuntimeEvent) bool) provider.RuntimeEvent {
	t.Helper()
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	for {
		select {
		case event := <-events:
			if match(event) {
				return event
			}
		case <-timer.C:
			t.Fatal("timed out waiting for Codex runtime event")
		}
	}
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
			var params skillsListParams
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
			if err := writeFakeResult(encoder, message["id"], response); err != nil {
				return err
			}
		case "thread/resume":
			var params struct {
				ThreadID string `json:"threadId"`
			}
			if err := decodeFakeParams(message, &params); err != nil || params.ThreadID != "native-thread" {
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
			clientID := "local-turn"
			if scenario == "message-identities" {
				clientID = "client-start"
			}
			if err := validateTurnStart(message, clientID); err != nil {
				return err
			}
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
			if scenario == "approval" || scenario == "approval-stop" || scenario == "server-resolved" || scenario == "exit-with-approval" {
				if err := writeFakeRequest(encoder, json.RawMessage("77"), "item/commandExecution/requestApproval", map[string]any{
					"threadId": "native-thread", "turnId": "native-turn", "itemId": "command-1", "startedAtMs": 1,
					"approvalId": "approval-1", "reason": "needs approval", "command": "echo hello", "cwd": "/tmp", "environmentId": nil,
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
		case "qa/malformed":
			if _, err := fmt.Fprintln(os.Stdout, "{not-json}"); err != nil {
				return err
			}
		case "turn/steer":
			clientID := "local-turn"
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
			var params turnInterruptParams
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
			if err := decodeFakeParams(message, &params); err != nil || params.ThreadID != "native-thread" || params.LastTurnID != "" || params.Model != "fork-model" || params.Config.Effort != "low" {
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
		case "thread/unsubscribe":
			if scenario == "stop-active" && !interrupted {
				return fmt.Errorf("active thread unsubscribed before interrupt")
			}
			if err := writeFakeResult(encoder, message["id"], map[string]any{"status": "unsubscribed"}); err != nil {
				return err
			}
		case "":
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
	}
	if err := decodeFakeParams(message, &params); err != nil {
		return err
	}
	if params.ThreadID != "native-thread" || params.ClientUserMessageID != clientID || len(params.Input) != 1 || params.Input[0].Type != "text" || params.Input[0].Text != "hello" {
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

func writeFakeNotification(encoder *json.Encoder, method string, params any) error {
	return encoder.Encode(struct {
		Method string `json:"method"`
		Params any    `json:"params"`
	}{Method: method, Params: params})
}
