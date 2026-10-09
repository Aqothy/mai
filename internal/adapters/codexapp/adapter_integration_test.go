package codexapp

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"slices"
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
		{ThreadID: "local-thread", TurnID: "local-turn", Input: "one more detail", ClientMessageID: "client-steer", Steer: true},
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
	if tier, ok := provider.CurrentConfigString(result.Session.ConfigOptions, "service_tier"); !ok || tier != defaultServiceTier {
		t.Fatalf("default service tier = %q, %v; options = %#v", tier, ok, result.Session.ConfigOptions)
	}
	if err := instance.SendTurn(testContext(t), provider.SendTurnInput{ThreadID: "local-thread", TurnID: "local-turn", Input: "hello"}); err != nil {
		t.Fatalf("start turn: %v", err)
	}
	if err := instance.SendTurn(testContext(t), provider.SendTurnInput{ThreadID: "local-thread", TurnID: "local-turn", Input: "one more detail", Steer: true}); err != nil {
		t.Fatalf("steer turn: %v", err)
	}

	title := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventThreadMetadataUpdate && event.Payload.Title != ""
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
	// A steer that lost the race with the turn's end reports it, so
	// orchestration sends the prompt as the next turn.
	if err := instance.SendTurn(testContext(t), provider.SendTurnInput{ThreadID: "local-thread", TurnID: "local-turn", Input: "too late", Steer: true}); !errors.Is(err, provider.ErrTurnNotRunning) {
		t.Fatalf("steer after turn completion err = %v, want ErrTurnNotRunning", err)
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

// A maiD rename names the Codex thread.
func TestRenameSessionSetsThreadName(t *testing.T) {
	instance := openFakeInstance(t, "lifecycle", nil)
	if err := instance.RenameSession(testContext(t), provider.RenameSessionInput{ProviderSessionID: "native-thread", Title: "Renamed in maiD"}); err != nil {
		t.Fatalf("rename: %v", err)
	}
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
	tier, ok := provider.CurrentConfigString(result.Session.ConfigOptions, "service_tier")
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
				if got, ok := provider.CurrentConfigString(result.Session.ConfigOptions, "reasoning_effort"); !ok || got != want {
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
	tier, ok := provider.CurrentConfigString(result.Session.ConfigOptions, "service_tier")
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

	browser, err := instance.Authenticate(testContext(t), provider.AuthenticateInput{MethodID: authMethodChatGPT})
	if err != nil {
		t.Fatalf("browser login: %v", err)
	}
	if browser.Challenge == nil || browser.Challenge.Kind != "browser" || browser.Challenge.URL != "https://example.test/auth" {
		t.Fatalf("browser challenge = %#v", browser.Challenge)
	}

	device, err := instance.Authenticate(testContext(t), provider.AuthenticateInput{MethodID: authMethodDevice})
	if err != nil {
		t.Fatalf("device login: %v", err)
	}
	if device.Challenge == nil || device.Challenge.Kind != "device-code" || device.Challenge.UserCode != "ABCD-EFGH" {
		t.Fatalf("device challenge = %#v", device.Challenge)
	}

	apiKey, err := instance.Authenticate(testContext(t), provider.AuthenticateInput{MethodID: authMethodAPIKey, Secret: "sk-test"})
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
	_, err := instance.Authenticate(testContext(t), provider.AuthenticateInput{MethodID: authMethodChatGPT})
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
	waitForAcceptedReply(t, events)
}

// A permissions preset chosen for a new thread rides thread/start; one picked
// mid-thread rides the next turn/start only, since turn settings persist.
func TestPermissionsPresetFlowsThroughThreadAndTurn(t *testing.T) {
	instance := openFakeInstance(t, "permissions", nil)
	result, err := instance.StartSession(testContext(t), provider.StartSessionInput{
		ThreadID: "local-thread", Cwd: "/tmp",
		ConfigSelections: []provider.ConfigOptionSelection{{OptionID: permissionsOptionID, Value: "full-access"}},
	})
	if err != nil {
		t.Fatalf("start session: %v", err)
	}
	if got, _ := provider.CurrentConfigString(result.Session.ConfigOptions, permissionsOptionID); got != "full-access" {
		t.Fatalf("session permissions = %q", got)
	}
	if err := instance.SetConfigOption(testContext(t), provider.SetConfigOptionInput{ThreadID: "local-thread", OptionID: permissionsOptionID, Value: customPermissions}); err == nil {
		t.Fatal("custom permissions were accepted as a selection")
	}
	if err := instance.SetConfigOption(testContext(t), provider.SetConfigOptionInput{ThreadID: "local-thread", OptionID: permissionsOptionID, Value: "read-only"}); err != nil {
		t.Fatalf("set permissions: %v", err)
	}
	// The fake checks the first turn carries the preset and the next none.
	for _, turn := range []string{"local-turn", "next-turn"} {
		if err := instance.SendTurn(testContext(t), provider.SendTurnInput{ThreadID: "local-thread", TurnID: turn, Input: "hello", ClientMessageID: "local-turn"}); err != nil {
			t.Fatalf("start %s: %v", turn, err)
		}
	}
}

// A request for more sandbox access is granted as asked, for the session
// when the user allows it for the session. Context usage is the newest
// request's, not the thread's running total.
func TestInstanceGrantsRequestedPermissions(t *testing.T) {
	events := make(chan provider.RuntimeEvent, 32)
	instance := openFakeInstance(t, "permissions-request", func(event provider.RuntimeEvent) { events <- event })
	startFakeTurn(t, instance)

	usage := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventThreadTokenUsage
	})
	if got := usage.Payload.TokenUsage; got == nil || got.UsedTokens != 1200 || got.MaxTokens != 200000 {
		t.Fatalf("token usage = %#v", got)
	}
	opened := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventRequestOpened
	})
	if opened.Payload.Detail != "Codex asks for network access" || opened.Payload.RequestType != provider.RuntimeRequestCommandExecution || len(opened.Payload.Options) != 3 {
		t.Fatalf("permissions request = %#v", opened.Payload)
	}
	if err := instance.RespondToRequest(testContext(t), provider.RespondToRequestInput{ThreadID: "local-thread", RequestID: opened.RequestID, OptionID: "acceptForSession"}); err != nil {
		t.Fatalf("respond: %v", err)
	}
	waitForAcceptedReply(t, events)
}

// Like the Codex TUI, a command approval offers Codex's proposed rule, and
// choosing it approves the command and adds the rule.
func TestInstanceApprovalOffersProposedRule(t *testing.T) {
	events := make(chan provider.RuntimeEvent, 32)
	instance := openFakeInstance(t, "approval-amendment", func(event provider.RuntimeEvent) { events <- event })
	startFakeTurn(t, instance)
	opened := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventRequestOpened
	})
	index := slices.IndexFunc(opened.Payload.Options, func(option provider.ApprovalOption) bool { return option.ID == "acceptWithExecpolicyAmendment" })
	if index < 0 || opened.Payload.Options[index].Name != "Always allow commands that start with `echo hello`" {
		t.Fatalf("options = %#v", opened.Payload.Options)
	}
	if err := instance.RespondToRequest(testContext(t), provider.RespondToRequestInput{ThreadID: "local-thread", RequestID: opened.RequestID, OptionID: "acceptWithExecpolicyAmendment"}); err != nil {
		t.Fatalf("respond: %v", err)
	}
	waitForAcceptedReply(t, events)
}

// A turn's failure shows once, on the failed turn; errors Codex retries and
// model reroutes are warnings.
func TestTurnFailureShowsOnce(t *testing.T) {
	events := make(chan provider.RuntimeEvent, 32)
	instance := openFakeInstance(t, "turn-failure", func(event provider.RuntimeEvent) { events <- event })
	startFakeTurn(t, instance)
	var warnings, errors []string
	for {
		event := waitForRuntimeEvent(t, events, func(provider.RuntimeEvent) bool { return true })
		switch event.Type {
		case provider.RuntimeEventRuntimeWarning:
			warnings = append(warnings, event.Payload.Message)
		case provider.RuntimeEventRuntimeError:
			errors = append(errors, event.Payload.Message)
		case provider.RuntimeEventTurnCompleted:
			want := []string{"Reconnecting 1/5", "Codex switched from gpt-test to gpt-safe for this turn (highRiskCyberActivity)."}
			if !slices.Equal(warnings, want) || len(errors) != 0 || event.Payload.TurnState != provider.RuntimeTurnFailed || event.Payload.Message != "boom" {
				t.Fatalf("warnings %q, errors %q, turn %s %q", warnings, errors, event.Payload.TurnState, event.Payload.Message)
			}
			return
		}
	}
}

// waitForAcceptedReply waits for the fake app-server to complete the turn,
// which it does only after receiving the reply it expects.
func waitForAcceptedReply(t *testing.T, events <-chan provider.RuntimeEvent) {
	t.Helper()
	completed := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventTurnCompleted
	})
	if completed.Payload.TurnState != provider.RuntimeTurnCompleted {
		t.Fatalf("turn = %q %q, want completed after the expected reply", completed.Payload.TurnState, completed.Payload.Message)
	}
}

// A Codex MCP server's form elicitation is asked as a user-input question and
// answered with typed content.
func TestInstanceAnswersMCPElicitation(t *testing.T) {
	events := make(chan provider.RuntimeEvent, 32)
	instance := openFakeInstance(t, "elicitation", func(event provider.RuntimeEvent) { events <- event })
	startFakeTurn(t, instance)

	opened := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventRequestOpened
	})
	if opened.Payload.UserInput == nil || len(opened.Payload.UserInput.Questions) != 1 {
		t.Fatalf("elicitation opened = %#v", opened.Payload)
	}
	if err := instance.RespondToRequest(testContext(t), provider.RespondToRequestInput{ThreadID: "local-thread", RequestID: opened.RequestID, Decision: provider.ApprovalDecisionAccept, Answers: map[string][]string{"confirmed": {"true"}}}); err != nil {
		t.Fatalf("respond to elicitation: %v", err)
	}
	resolved := waitForRuntimeEvent(t, events, func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventRequestResolved
	})
	if resolved.Payload.Decision != provider.ApprovalDecisionAccept || resolved.Payload.Answers["confirmed"][0] != "true" {
		t.Fatalf("elicitation resolved payload = %#v", resolved.Payload)
	}
	waitForAcceptedReply(t, events)
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
			} else {
				instance.process.Kill()
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
		Env:     map[string]string{fakeAppServerEnvironment: "1", "GORACE": "atexit_sleep_ms=0"},
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
	turnStarted := false
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
