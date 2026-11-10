package codexapp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/provider/providertest"
)

// The fake app-server's thread.
const nativeThread = "native-thread"

type testInstance struct {
	*Instance
	events *providertest.Recorder
}

func openFakeInstance(t *testing.T, scenario string) testInstance {
	t.Helper()
	config, err := json.Marshal(Config{
		Command: []string{os.Args[0], "-test.run=^TestCodexAppServerHelperProcess$", "--", scenario},
		Env:     map[string]string{fakeAppServerEnvironment: "1", "GORACE": "atexit_sleep_ms=0"},
	})
	if err != nil {
		t.Fatal(err)
	}
	events := providertest.NewRecorder()
	instance, err := OpenInstance(testContext(t), provider.InstanceSpec{InstanceID: "codex-test", Name: "Codex Test", Driver: DriverKind, Config: config}, provider.Host{Emit: events.Emit, Mirror: providertest.NewMirror()})
	if err != nil {
		t.Fatalf("open fake app-server: %v", err)
	}
	t.Cleanup(func() { _ = instance.Close() })
	return testInstance{Instance: instance, events: events}
}

func (h testInstance) open(t *testing.T, in provider.OpenInput) provider.Opened {
	t.Helper()
	in.Workspace.Cwd = "/tmp"
	opened, err := h.Open(testContext(t), in)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	return opened
}

func (h testInstance) send(t *testing.T, delivery, text string, steer bool) provider.SendAck {
	t.Helper()
	ack, err := h.Send(testContext(t), nativeThread, provider.SendInput{Delivery: delivery, Text: text, Steer: steer})
	if err != nil {
		t.Fatalf("send %q: %v", text, err)
	}
	return ack
}

// startFakeTurn opens the fake thread and starts the turn its scenario
// scripts, whose delivery the fake expects to be "local-turn".
func (h testInstance) startFakeTurn(t *testing.T) {
	t.Helper()
	h.open(t, provider.OpenInput{})
	h.send(t, "local-turn", "hello", false)
}

func (h testInstance) request(t *testing.T) provider.RequestOpened {
	t.Helper()
	return h.events.WaitFor(t, "a request", func(event provider.Event) bool {
		_, ok := event.Body.(provider.RequestOpened)
		return ok
	}).Body.(provider.RequestOpened)
}

func (h testInstance) resolved(t *testing.T, request string) provider.RequestResolved {
	t.Helper()
	return h.events.WaitFor(t, "the request to resolve", func(event provider.Event) bool {
		resolved, ok := event.Body.(provider.RequestResolved)
		return ok && resolved.Request == request
	}).Body.(provider.RequestResolved)
}

// answer responds with one of the request's own actions, as the engine does.
func (h testInstance) answer(t *testing.T, request provider.RequestOpened, actionID string, answers map[string][]string) error {
	t.Helper()
	action, ok := request.Ask.Action(actionID)
	if !ok {
		t.Fatalf("request %s offers no action %q: %#v", request.Request, actionID, request.Ask)
	}
	return h.Respond(testContext(t), nativeThread, request.Request, provider.RequestAnswer{Action: action, Answers: answers})
}

func (h testInstance) settled(t *testing.T, turn string) provider.TurnSettled {
	t.Helper()
	return h.events.WaitFor(t, "turn "+turn+" to settle", providertest.Settled(turn)).Body.(provider.TurnSettled)
}

// requireCompleted waits for the fake to complete its turn, which it does
// only after receiving the reply it expects.
func (h testInstance) requireCompleted(t *testing.T) {
	t.Helper()
	if settled := h.settled(t, "native-turn"); settled.State != provider.TurnCompleted {
		t.Fatalf("turn = %#v, want completed after the expected reply", settled)
	}
}

func (h testInstance) started(t *testing.T, turn string) provider.TurnStarted {
	t.Helper()
	return h.events.WaitFor(t, "turn "+turn+" to start", func(event provider.Event) bool {
		started, ok := event.Body.(provider.TurnStarted)
		return ok && started.Turn == turn
	}).Body.(provider.TurnStarted)
}

// assistantText is what the turn's assistant entries say so far, Local ones
// (an adapter's own reports) included.
func (h testInstance) assistantText(turn string) string {
	var builder provider.HistoryBuilder
	for _, event := range h.events.Snapshot() {
		if event.Session == nativeThread {
			builder.Add(event)
		}
	}
	var text strings.Builder
	for _, live := range builder.Turns() {
		if live.Ref != turn {
			continue
		}
		for _, entry := range live.Entries {
			if entry.Kind == provider.ItemKindAssistantMessage {
				text.WriteString(entry.Text)
			}
		}
	}
	return text.String()
}

func testContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func TestInstanceUsesDistinctClientMessageIDsForSteering(t *testing.T) {
	h := openFakeInstance(t, "message-identities")
	h.open(t, provider.OpenInput{})
	if ack := h.send(t, "client-start", "hello", false); ack.Turn != "native-turn" {
		t.Fatalf("ack = %#v, want Codex's turn", ack)
	}
	if ack := h.send(t, "client-steer", "one more detail", true); ack.Turn != "native-turn" {
		t.Fatalf("steer ack = %#v", ack)
	}
}

// Codex can end a turn before the adapter reads its turn/completed. A steer
// it refuses for that is a steer that missed its turn, which orchestration
// sends as the next turn; a turn that can't take input refuses the steer.
func TestSteerRefusedByAnEndedTurnMissedIt(t *testing.T) {
	h := openFakeInstance(t, "steer-race")
	h.startFakeTurn(t)
	steer := func(text string) error {
		_, err := h.Send(testContext(t), nativeThread, provider.SendInput{Delivery: "steer-" + text, Text: text, Steer: true})
		return err
	}
	if err := steer("too late"); !errors.Is(err, provider.ErrTurnNotRunning) {
		t.Fatalf("steer into an ended turn err = %v, want ErrTurnNotRunning", err)
	}
	if err := steer("into a review"); err == nil || errors.Is(err, provider.ErrTurnNotRunning) || !strings.Contains(err.Error(), "cannot steer a review turn") {
		t.Fatalf("steer into a review err = %v, want the refusal", err)
	}
}

func TestInstanceStableLifecycleWireFlow(t *testing.T) {
	h := openFakeInstance(t, "lifecycle")
	opened := h.open(t, provider.OpenInput{})
	if opened.Session != nativeThread {
		t.Fatalf("session = %q", opened.Session)
	}
	if tier, ok := provider.CurrentConfigString(opened.Options, "service_tier"); !ok || tier != defaultServiceTier {
		t.Fatalf("default service tier = %q, %v; options = %#v", tier, ok, opened.Options)
	}
	if started := h.send(t, "local-turn", "hello", false); started.Turn != "native-turn" {
		t.Fatalf("ack = %#v", started)
	}
	h.send(t, "steer-1", "one more detail", true)
	title := h.events.WaitFor(t, "the title", func(event provider.Event) bool {
		_, ok := event.Body.(provider.TitleChanged)
		return ok
	}).Body.(provider.TitleChanged)
	if title.Title != "Protocol title" {
		t.Fatalf("title = %q", title.Title)
	}

	// Codex keeps a fork loaded, so the fork request itself carries the
	// source's model and reasoning. It ends through the chosen turn.
	fork, err := h.Fork(testContext(t), provider.ForkInput{
		Session: nativeThread, Through: "native-earlier-turn", Workspace: provider.Workspace{Cwd: "/tmp"},
		Settings: []provider.ConfigOptionSelection{{OptionID: "model", Value: "fork-model"}, {OptionID: "reasoning_effort", Value: "low"}},
	})
	if err != nil {
		t.Fatalf("fork: %v", err)
	}
	if fork != "forked-thread" {
		t.Fatalf("fork = %q", fork)
	}
	if settled := h.settled(t, "native-turn"); settled.State != provider.TurnFailed || !strings.Contains(settled.Error, "model failed") {
		t.Fatalf("failed turn = %#v", settled)
	}
	// A steer that lost the race with the turn's end reports it, so
	// orchestration sends the prompt as the next turn.
	if _, err := h.Send(testContext(t), nativeThread, provider.SendInput{Delivery: "steer-2", Text: "too late", Steer: true}); !errors.Is(err, provider.ErrTurnNotRunning) {
		t.Fatalf("steer after turn completion err = %v, want ErrTurnNotRunning", err)
	}
	if err := h.Release(testContext(t), nativeThread); err != nil {
		t.Fatalf("release: %v", err)
	}
	if err := h.Close(); err != nil {
		t.Fatalf("intentional close: %v", err)
	}
}

func TestResumeBindsBeforeNotificationsAndRejectsIdentityChanges(t *testing.T) {
	t.Run("notification before response", func(t *testing.T) {
		h := openFakeInstance(t, "resume-notification")
		if opened := h.open(t, provider.OpenInput{Session: nativeThread}); opened.Session != nativeThread {
			t.Fatalf("resumed session = %q", opened.Session)
		}
		title := h.events.WaitFor(t, "the early title", func(event provider.Event) bool {
			_, ok := event.Body.(provider.TitleChanged)
			return ok
		})
		if title.Session != nativeThread || title.Body.(provider.TitleChanged).Title != "Resumed before response" {
			t.Fatalf("early resume notification = %#v", title)
		}
	})

	t.Run("changed identity", func(t *testing.T) {
		h := openFakeInstance(t, "resume-wrong-identity")
		if _, err := h.Open(testContext(t), provider.OpenInput{Session: nativeThread, Workspace: provider.Workspace{Cwd: "/tmp"}}); err == nil {
			t.Fatal("resume accepted a different native thread id")
		}
		h.mu.Lock()
		session := h.sessions[nativeThread]
		h.mu.Unlock()
		if session != nil && session.loaded {
			t.Fatalf("failed resume left the thread loaded: %#v", session)
		}
	})
}

// A maiD rename names the Codex thread.
func TestRenameSetsThreadName(t *testing.T) {
	h := openFakeInstance(t, "lifecycle")
	if err := h.Rename(testContext(t), nativeThread, "Renamed in maiD"); err != nil {
		t.Fatalf("rename: %v", err)
	}
}

func TestOpenReusesTheLoadedThread(t *testing.T) {
	h := openFakeInstance(t, "lifecycle")
	h.open(t, provider.OpenInput{})
	h.mu.Lock()
	existing := h.sessions[nativeThread]
	existing.entries["command-1"] = provider.Entry{Ref: "command-1"}
	h.mu.Unlock()
	if opened := h.open(t, provider.OpenInput{Session: nativeThread}); opened.Session != nativeThread {
		t.Fatalf("reopened = %#v", opened)
	}
	h.mu.Lock()
	reused := h.sessions[nativeThread]
	_, kept := reused.entries["command-1"]
	h.mu.Unlock()
	if reused != existing || !kept {
		t.Fatalf("the loaded thread was replaced: reused=%t kept=%t", reused == existing, kept)
	}
}

func TestReleaseInterruptsActiveTurnBeforeUnsubscribe(t *testing.T) {
	h := openFakeInstance(t, "stop-active")
	h.startFakeTurn(t)
	if err := h.Release(testContext(t), nativeThread); err != nil {
		t.Fatalf("release an active thread: %v", err)
	}
}

func TestServiceTierFlowsThroughSessionAndTurnRequests(t *testing.T) {
	h := openFakeInstance(t, "service-tier")
	opened := h.open(t, provider.OpenInput{Settings: []provider.ConfigOptionSelection{{OptionID: "service_tier", Value: "priority"}}})
	if tier, ok := provider.CurrentConfigString(opened.Options, "service_tier"); !ok || tier != "priority" {
		t.Fatalf("session service tier = %q, %v; options = %#v", tier, ok, opened.Options)
	}
	h.send(t, "local-turn", "hello", false)
}

func TestReasoningEffortFlowsThroughNewAndResumedSessions(t *testing.T) {
	for _, session := range []string{"", nativeThread} {
		for _, selected := range []bool{false, true} {
			t.Run(fmt.Sprintf("session=%s/selected=%t", session, selected), func(t *testing.T) {
				scenario, want := "reasoning-default", "medium"
				in := provider.OpenInput{Session: session}
				if selected {
					scenario, want = "reasoning-low", "low"
					in.Settings = []provider.ConfigOptionSelection{{OptionID: "reasoning_effort", Value: want}}
				}
				h := openFakeInstance(t, scenario)
				opened := h.open(t, in)
				if got, ok := provider.CurrentConfigString(opened.Options, "reasoning_effort"); !ok || got != want {
					t.Fatalf("session effort = %q, %v; want %q", got, ok, want)
				}
				h.send(t, "local-turn", "hello", false)
			})
		}
	}
}

func TestAuthoritativeNullServiceTierRemainsStandard(t *testing.T) {
	h := openFakeInstance(t, "catalog-priority-default")
	opened := h.open(t, provider.OpenInput{Session: nativeThread})
	if tier, ok := provider.CurrentConfigString(opened.Options, "service_tier"); !ok || tier != defaultServiceTier {
		t.Fatalf("authoritative null tier = %q, %v; options = %#v", tier, ok, opened.Options)
	}
	h.mu.Lock()
	stored := h.sessions[nativeThread].serviceTier
	h.mu.Unlock()
	if stored != defaultServiceTier {
		t.Fatalf("stored service tier = %q", stored)
	}
}

func TestInstanceAccountLoginUnionsAndParameterlessLogout(t *testing.T) {
	h := openFakeInstance(t, "auth")
	browser, err := h.Authenticate(testContext(t), provider.AuthenticateInput{MethodID: authMethodChatGPT})
	if err != nil {
		t.Fatalf("browser login: %v", err)
	}
	if browser.Challenge == nil || browser.Challenge.Kind != "browser" || browser.Challenge.URL != "https://example.test/auth" {
		t.Fatalf("browser challenge = %#v", browser.Challenge)
	}
	device, err := h.Authenticate(testContext(t), provider.AuthenticateInput{MethodID: authMethodDevice})
	if err != nil {
		t.Fatalf("device login: %v", err)
	}
	if device.Challenge == nil || device.Challenge.Kind != "device-code" || device.Challenge.UserCode != "ABCD-EFGH" {
		t.Fatalf("device challenge = %#v", device.Challenge)
	}
	apiKey, err := h.Authenticate(testContext(t), provider.AuthenticateInput{MethodID: authMethodAPIKey, Secret: "sk-test"})
	if err != nil {
		t.Fatalf("API key login: %v", err)
	}
	if apiKey.Instance.Auth.Status != provider.AuthStatusAuthenticated {
		t.Fatalf("API key auth status = %q", apiKey.Instance.Auth.Status)
	}
	loggedOut, err := h.Logout(testContext(t))
	if err != nil {
		t.Fatalf("logout: %v", err)
	}
	if loggedOut.Auth.Status != provider.AuthStatusUnauthenticated {
		t.Fatalf("logout auth status = %q", loggedOut.Auth.Status)
	}
}

func TestInstanceRejectsMismatchedAccountLoginUnion(t *testing.T) {
	h := openFakeInstance(t, "bad-auth-union")
	if _, err := h.Authenticate(testContext(t), provider.AuthenticateInput{MethodID: authMethodChatGPT}); err == nil || !strings.Contains(err.Error(), "returned type") {
		t.Fatalf("mismatched login error = %v", err)
	}
}

func TestOptionsIncludeCwdScopedSkills(t *testing.T) {
	h := openFakeInstance(t, "options")
	opened, err := h.OpenOptions(testContext(t), "/workspace", provider.OptionsSessionCallbacks{})
	if err != nil {
		t.Fatalf("open options: %v", err)
	}
	if len(opened.Skills) != 1 {
		t.Fatalf("options skills = %#v", opened.Skills)
	}
	if skill := opened.Skills[0]; skill.Name != "review" || skill.Path != "/skills/review" || skill.ShortDescription != "Review changes" || !skill.Enabled {
		t.Fatalf("options skill = %#v", skill)
	}
}

func TestOptionsRecoverWhenSkillsListFails(t *testing.T) {
	h := openFakeInstance(t, "skills-error")
	opened, err := h.OpenOptions(testContext(t), "/workspace", provider.OptionsSessionCallbacks{})
	if err != nil {
		t.Fatalf("open options: %v", err)
	}
	if opened.Handle == "" || len(opened.ConfigOptions) == 0 || opened.ConfigOptions[0].CurrentValue != "gpt-test" || len(opened.Skills) != 0 {
		t.Fatalf("options after failed skills/list = %#v", opened)
	}
}

func TestInstanceApprovalResponseUsesStableDecision(t *testing.T) {
	h := openFakeInstance(t, "approval")
	h.startFakeTurn(t)
	request := h.request(t)
	if request.Request != "approval-1" || request.Turn != "native-turn" || request.Entry != "command-1" {
		t.Fatalf("approval = %#v", request)
	}
	// Each action is named after the Codex decision it sends.
	decisions := map[string]provider.ApprovalDecision{}
	for _, action := range request.Ask.Actions {
		decisions[action.ID] = action.Decision
	}
	if decisions["accept"] != provider.ApprovalDecisionAccept || decisions["acceptForSession"] != provider.ApprovalDecisionAcceptForSession || decisions["decline"] != provider.ApprovalDecisionDecline {
		t.Fatalf("approval action decisions = %v", decisions)
	}
	if err := h.answer(t, request, "acceptForSession", nil); err != nil {
		t.Fatalf("respond to approval: %v", err)
	}
	if resolved := h.resolved(t, request.Request); resolved.Action != "acceptForSession" {
		t.Fatalf("approval resolved = %#v", resolved)
	}
	h.requireCompleted(t)
}

// A permissions preset chosen for a new thread rides thread/start; one picked
// mid-thread rides the next turn/start only, since turn settings persist.
func TestPermissionsPresetFlowsThroughThreadAndTurn(t *testing.T) {
	h := openFakeInstance(t, "permissions")
	opened := h.open(t, provider.OpenInput{Settings: []provider.ConfigOptionSelection{{OptionID: permissionsOptionID, Value: "full-access"}}})
	if got, _ := provider.CurrentConfigString(opened.Options, permissionsOptionID); got != "full-access" {
		t.Fatalf("session permissions = %q", got)
	}
	if err := h.Configure(testContext(t), nativeThread, provider.ConfigOptionSelection{OptionID: permissionsOptionID, Value: customPermissions}); err == nil {
		t.Fatal("custom permissions were accepted as a selection")
	}
	if err := h.Configure(testContext(t), nativeThread, provider.ConfigOptionSelection{OptionID: permissionsOptionID, Value: "read-only"}); err != nil {
		t.Fatalf("set permissions: %v", err)
	}
	// The fake checks the first turn carries the preset and the next none.
	for range 2 {
		h.send(t, "local-turn", "hello", false)
	}
}

// A request for more sandbox access is granted as asked, for the session
// when the user allows it for the session. Context usage is the newest
// request's, not the thread's running total.
func TestInstanceGrantsRequestedPermissions(t *testing.T) {
	h := openFakeInstance(t, "permissions-request")
	h.startFakeTurn(t)
	usage := h.events.WaitFor(t, "the usage", func(event provider.Event) bool {
		_, ok := event.Body.(provider.UsageChanged)
		return ok
	}).Body.(provider.UsageChanged)
	if usage.Usage.UsedTokens != 1200 || usage.Usage.MaxTokens != 200000 {
		t.Fatalf("token usage = %#v", usage.Usage)
	}
	request := h.request(t)
	if request.Ask.Message != "Codex asks for network access" || len(request.Ask.Actions) != 3 {
		t.Fatalf("permissions request = %#v", request.Ask)
	}
	if err := h.answer(t, request, "session", nil); err != nil {
		t.Fatalf("respond: %v", err)
	}
	h.requireCompleted(t)
}

// Like the Codex TUI, a command approval offers Codex's proposed rule, and
// choosing it approves the command and adds the rule.
func TestInstanceApprovalOffersProposedRule(t *testing.T) {
	h := openFakeInstance(t, "approval-amendment")
	h.startFakeTurn(t)
	request := h.request(t)
	if rule, ok := request.Ask.Action("acceptWithExecpolicyAmendment"); !ok || rule.Label != "Always allow commands that start with `echo hello`" {
		t.Fatalf("actions = %#v", request.Ask.Actions)
	}
	if err := h.answer(t, request, "acceptWithExecpolicyAmendment", nil); err != nil {
		t.Fatalf("respond: %v", err)
	}
	h.requireCompleted(t)
}

// A turn's failure shows once, on the failed turn; errors Codex retries and
// model reroutes are warnings.
func TestTurnFailureShowsOnce(t *testing.T) {
	h := openFakeInstance(t, "turn-failure")
	h.startFakeTurn(t)
	settled := h.settled(t, "native-turn")
	var warnings []string
	for _, event := range h.events.Snapshot() {
		if warning, ok := event.Body.(provider.Warning); ok {
			warnings = append(warnings, warning.Message)
		}
	}
	want := []string{"Reconnecting 1/5", "Codex switched from gpt-test to gpt-safe for this turn (highRiskCyberActivity)."}
	if !slices.Equal(warnings, want) || settled.State != provider.TurnFailed || settled.Error != "boom" {
		t.Fatalf("warnings %q, turn %#v", warnings, settled)
	}
}

// A Codex MCP server's form elicitation is asked as a user-input question and
// answered with typed content.
func TestInstanceAnswersMCPElicitation(t *testing.T) {
	h := openFakeInstance(t, "elicitation")
	h.startFakeTurn(t)
	request := h.request(t)
	if len(request.Ask.Questions) != 1 {
		t.Fatalf("elicitation = %#v", request.Ask)
	}
	if err := h.answer(t, request, "accept", map[string][]string{"confirmed": {"true"}}); err != nil {
		t.Fatalf("respond to elicitation: %v", err)
	}
	if resolved := h.resolved(t, request.Request); resolved.Action != "accept" || resolved.Answers["confirmed"][0] != "true" {
		t.Fatalf("elicitation resolved = %#v", resolved)
	}
	h.requireCompleted(t)
}

// An MCP tool approval asks for nothing but yes or no, so it is a permission
// request rather than a question, offering the ways to keep allowing that
// Codex lists; the chosen one goes back in the response's _meta.
func TestInstanceAsksMCPToolApprovalAsPermission(t *testing.T) {
	h := openFakeInstance(t, "mcp-tool-approval")
	h.startFakeTurn(t)
	request := h.request(t)
	if len(request.Ask.Questions) != 0 {
		t.Fatalf("tool approval asks questions: %#v", request.Ask.Questions)
	}
	var actions []string
	for _, action := range request.Ask.Actions {
		actions = append(actions, action.ID+"="+action.Label)
	}
	if want := []string{"accept=Allow", "persist:session=Allow for this session", "persist:always=Always allow", "decline=Decline"}; !slices.Equal(actions, want) {
		t.Fatalf("actions = %v, want %v", actions, want)
	}
	if !strings.Contains(string(request.Ask.Details), `run tool \"search\"?`) {
		t.Fatalf("details = %s, want the request's message", request.Ask.Details)
	}
	if err := h.answer(t, request, "persist:session", nil); err != nil {
		t.Fatalf("respond to tool approval: %v", err)
	}
	if resolved := h.resolved(t, request.Request); resolved.Action != "persist:session" {
		t.Fatalf("tool approval resolved = %#v", resolved)
	}
	h.requireCompleted(t)
}

// Requests end without an answer when their thread is released, Codex
// resolves them itself, or app-server exits; answering one then fails.
func TestPendingRequestsEndWithoutAnAnswer(t *testing.T) {
	for _, scenario := range []string{"approval-stop", "server-resolved", "exit-with-approval"} {
		t.Run(scenario, func(t *testing.T) {
			h := openFakeInstance(t, scenario)
			h.startFakeTurn(t)
			request := h.request(t)
			if scenario == "approval-stop" {
				if err := h.Release(testContext(t), nativeThread); err != nil {
					t.Fatalf("release: %v", err)
				}
			}
			if resolved := h.resolved(t, request.Request); resolved.Action != "" {
				t.Fatalf("resolution = %#v, want no answer", resolved)
			}
			if scenario == "server-resolved" {
				if err := h.answer(t, request, "accept", nil); err == nil {
					t.Fatal("answering a server-resolved approval succeeded")
				}
			}
		})
	}
}

// app-server exiting ends the running turn once: interrupted when maiD
// closed it, failed (and the session closed) otherwise.
func TestProcessExitSettlesActiveTurn(t *testing.T) {
	for _, intentional := range []bool{false, true} {
		t.Run(fmt.Sprintf("intentional=%v", intentional), func(t *testing.T) {
			h := openFakeInstance(t, "lifecycle")
			h.startFakeTurn(t)
			if intentional {
				if err := h.Close(); err != nil {
					t.Fatal(err)
				}
			} else {
				h.process.Kill()
			}
			settled := h.settled(t, "native-turn")
			want := provider.TurnFailed
			if intentional {
				want = provider.TurnInterrupted
			}
			if settled.State != want || !intentional && !strings.Contains(settled.Error, "Codex") {
				t.Fatalf("exit settle = %#v, want %s", settled, want)
			}
			select {
			case <-h.processDone:
			case <-testContext(t).Done():
				t.Fatal("provider did not finish cleanup")
			}
			settles := 0
			for _, event := range h.events.Snapshot() {
				if _, ok := event.Body.(provider.TurnSettled); ok {
					settles++
				}
			}
			if settles != 1 {
				t.Fatalf("%d settles, want one", settles)
			}
		})
	}
}

func TestMalformedTransportSettlesTurnAndStopsProcess(t *testing.T) {
	h := openFakeInstance(t, "lifecycle")
	h.startFakeTurn(t)
	if err := h.rpc.notify("qa/malformed", nil); err != nil {
		t.Fatal(err)
	}
	if settled := h.settled(t, "native-turn"); settled.State != provider.TurnFailed || !strings.Contains(settled.Error, "decode Codex app-server message") {
		t.Fatalf("malformed transport outcome = %#v", settled)
	}
	select {
	case <-h.processDone:
	case <-testContext(t).Done():
		t.Fatal("unusable app-server process was left running")
	}
}

// A message whose turn Codex hasn't named when app-server dies ends once:
// Send fails, or (for an operation whose turn comes later) the session
// closes; no turn Codex never started settles.
func TestPendingTurnEndsOnceOnDisconnect(t *testing.T) {
	for _, input := range []string{"hello", "/compact"} {
		t.Run(input, func(t *testing.T) {
			h := openFakeInstance(t, "exit-before-turn")
			h.open(t, provider.OpenInput{})
			_, sendErr := h.Send(testContext(t), nativeThread, provider.SendInput{Delivery: "local-turn", Text: input})
			select {
			case <-h.processDone:
			case <-testContext(t).Done():
				t.Fatal("provider did not exit")
			}
			closed := false
			for _, event := range h.events.Snapshot() {
				switch event.Body.(type) {
				case provider.TurnSettled:
					t.Fatalf("a turn Codex never started settled: %#v", event)
				case provider.SessionClosed:
					closed = true
				}
			}
			if sendErr == nil && !closed {
				t.Fatal("the message neither failed nor lost its session")
			}
		})
	}
}

// The turn completes before its turn/start response arrives. Reactivating it
// from that late response would make the exit settle it a second time.
func TestCompletedTurnIsNotFailedOnProcessExit(t *testing.T) {
	h := openFakeInstance(t, "complete-and-exit")
	h.startFakeTurn(t)
	select {
	case <-h.processDone:
	case <-testContext(t).Done():
		t.Fatal("provider did not exit")
	}
	var settles []provider.TurnSettled
	for _, event := range h.events.Snapshot() {
		if settled, ok := event.Body.(provider.TurnSettled); ok {
			settles = append(settles, settled)
		}
	}
	if len(settles) != 1 || settles[0].State != provider.TurnCompleted {
		t.Fatalf("completed turn was lost or failed again on exit: %#v", settles)
	}
}

// Slash commands run Codex's own operations. A goal change shows in a turn of
// its own, whether or not the goal then starts a turn, which stays Codex's;
// goal and shell commands sent during a turn join it, and the commands that
// would replace it are refused.
func TestSlashCommandsRunCodexOperations(t *testing.T) {
	h := openFakeInstance(t, "commands")
	h.open(t, provider.OpenInput{})
	report := func(delivery, text string) string {
		t.Helper()
		ack := h.send(t, delivery, text, false)
		turn := ack.Turn
		if turn == "" {
			turn = h.events.WaitFor(t, "the command's turn", func(event provider.Event) bool {
				started, ok := event.Body.(provider.TurnStarted)
				return ok && started.Delivery == delivery
			}).Body.(provider.TurnStarted).Turn
		}
		h.settled(t, turn)
		return h.assistantText(turn)
	}

	if got := report("local-goal", "/goal ship it"); got != "Goal active: ship it" {
		t.Fatalf("goal report = %q", got)
	}
	typed := h.events.WaitFor(t, "the typed command", func(event provider.Event) bool {
		upserted, ok := event.Body.(provider.EntryUpserted)
		return ok && upserted.Entry.Kind == provider.ItemKindUserMessage && upserted.Entry.Delivery == "local-goal"
	}).Body.(provider.EntryUpserted).Entry
	if typed.Text != "/goal ship it" || !typed.Local {
		t.Fatalf("typed command = %#v, want a Local message", typed)
	}
	if started := h.started(t, "goal-turn"); started.By != provider.TurnByProvider {
		t.Fatalf("the goal's turn = %#v, want Codex's", started)
	}
	if ack := h.send(t, "local-pause", "/goal pause", true); ack.Turn != "goal-turn" {
		t.Fatalf("pause ack = %#v, want it in the running turn", ack)
	}
	h.events.WaitFor(t, "the pause report", func(event provider.Event) bool {
		upserted, ok := event.Body.(provider.EntryUpserted)
		return ok && upserted.Entry.Turn == "goal-turn" && upserted.Entry.Text == "Goal paused: ship it"
	})
	if _, err := h.Send(testContext(t), nativeThread, provider.SendInput{Delivery: "local-compact-steer", Text: "/compact", Steer: true}); err == nil || !strings.Contains(err.Error(), "can't run while Codex is working") {
		t.Fatalf("steered /compact err = %v, want it refused", err)
	}
	h.send(t, "local-shell-steer", "/shell pwd", true)
	h.events.WaitFor(t, "the shell command", func(event provider.Event) bool {
		upserted, ok := event.Body.(provider.EntryUpserted)
		return ok && upserted.Entry.Turn == "goal-turn" && upserted.Entry.Tool != nil && upserted.Entry.Tool.Command == "pwd"
	})
	h.settled(t, "goal-turn")

	if got := report("local-show", "/goal"); got != "Goal paused: ship it" {
		t.Fatalf("show report = %q", got)
	}
	// This objective starts no turn, so only its update ends the turn.
	if got := report("local-replace", "/goal next aim"); got != "Goal active: next aim" {
		t.Fatalf("replace report = %q", got)
	}
	if got := report("local-clear", "/goal clear"); got != "Goal cleared." {
		t.Fatalf("clear report = %q", got)
	}
	for _, command := range []struct{ delivery, text string }{
		{"local-shell", "/shell ls"},
		{"local-review", " /review look for races "},
		{"local-branch", "/review --base main"},
		{"local-compact", "/compact"},
	} {
		report(command.delivery, command.text)
	}
	// Like `codex review`, a review needs a target or instructions.
	if _, err := h.Send(testContext(t), nativeThread, provider.SendInput{Delivery: "local-bare", Text: "/review"}); err == nil || !strings.Contains(err.Error(), "Specify --uncommitted") {
		t.Fatalf("bare /review err = %v", err)
	}
}

// /review suggests the Codex CLI's targets, then a repository's branches or
// commits for the target picked; /goal suggests its controls.
func TestCommandCompletions(t *testing.T) {
	repo := t.TempDir()
	for _, args := range [][]string{
		{"init", "-q", "-b", "main"},
		{"-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "first change"},
		{"branch", "feature/login"},
		{"-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "second change"},
	} {
		if output, err := exec.Command("git", append([]string{"-C", repo}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, output)
		}
	}
	instance := &Instance{}
	labels := func(command, input string) []string {
		completions, err := instance.CompleteCommand(testContext(t), provider.CompleteCommandInput{Command: command, Input: input, Cwd: repo})
		if err != nil {
			t.Fatal(err)
		}
		var labels []string
		for _, completion := range completions {
			labels = append(labels, completion.Label+" => "+completion.Input)
		}
		return labels
	}
	for _, test := range []struct {
		command, input string
		want           []string
	}{
		{"review", "", []string{"Against a base branch => --base ", "Uncommitted changes => --uncommitted", "A commit => --commit "}},
		{"review", "--u", []string{"Uncommitted changes => --uncommitted"}},
		// The current branch is not a base to review against.
		{"review", "--base ", []string{"feature/login => --base feature/login"}},
		{"review", "--base main", nil},
		{"review", "look for races", nil},
		{"goal", "p", []string{"Pause the goal => pause"}},
		{"goal", "polish the docs", nil},
		{"shell", "", nil},
	} {
		if got := labels(test.command, test.input); !slices.Equal(got, test.want) {
			t.Errorf("/%s %q completions = %q, want %q", test.command, test.input, got, test.want)
		}
	}
	commits := labels("review", "--commit sec")
	if len(commits) != 1 || !strings.HasPrefix(commits[0], "second change => --commit ") {
		t.Errorf("commit completions = %q", commits)
	}
}

// A thread's goal is reported when it opens, and then each time it changes,
// cleared included.
func TestGoalIsReportedAsItChanges(t *testing.T) {
	h := openFakeInstance(t, "goal-resume")
	opened := h.open(t, provider.OpenInput{Session: nativeThread})
	budget := int64(100)
	want := &provider.Goal{Objective: "carry on", Status: provider.GoalBudgetLimited, TokensUsed: 150, TokenBudget: &budget, TimeUsedSeconds: 60}
	if !reflect.DeepEqual(opened.Goal, want) {
		t.Fatalf("opened goal = %#v, want %#v", opened.Goal, want)
	}
	goals := func() []*provider.Goal {
		var goals []*provider.Goal
		for _, event := range h.events.Snapshot() {
			if changed, ok := event.Body.(provider.GoalChanged); ok {
				goals = append(goals, changed.Goal)
			}
		}
		return goals
	}
	h.send(t, "local-clear", "/goal clear", false)
	h.events.WaitFor(t, "the goal to clear", func(event provider.Event) bool {
		changed, ok := event.Body.(provider.GoalChanged)
		return ok && changed.Goal == nil
	})
	h.send(t, "local-set", "/goal next aim", false)
	set := h.events.WaitFor(t, "the new goal", func(event provider.Event) bool {
		changed, ok := event.Body.(provider.GoalChanged)
		return ok && changed.Goal != nil
	}).Body.(provider.GoalChanged)
	if set.Goal.Objective != "next aim" || set.Goal.Status != provider.GoalActive {
		t.Fatalf("set goal = %#v (all %#v)", set.Goal, goals())
	}
}

// Codex runs turns of its own, such as a goal continuing. A message sent
// meanwhile joins it, as Codex steers turn/start input into a running turn;
// the turn stays Codex's, and the ack says the message joined it. Input
// Codex refuses fails the send and leaves Codex's turn running.
func TestUserMessageJoinsCodexOwnTurn(t *testing.T) {
	h := openFakeInstance(t, "handoff")
	h.open(t, provider.OpenInput{})
	h.send(t, "client-local-goal-/goal ship it", "/goal ship it", false)
	h.started(t, "goal-turn")

	if _, err := h.Send(testContext(t), nativeThread, provider.SendInput{Delivery: "client-local-refused-too long", Text: "too long"}); err == nil || !strings.Contains(err.Error(), "input too large") {
		t.Fatalf("refused send = %v", err)
	}
	ack := h.send(t, "client-local-turn-hello", "hello", false)
	if ack != (provider.SendAck{Turn: "goal-turn", Joined: true}) {
		t.Fatalf("ack = %#v, want it joined Codex's turn", ack)
	}
	h.settled(t, "goal-turn")
	if reply := h.assistantText("goal-turn"); reply != "hi" {
		t.Fatalf("reply = %q", reply)
	}

	// The goal continues with another turn; pausing it joins that one.
	h.started(t, "goal-turn-2")
	h.send(t, "client-local-pause-/goal pause", "/goal pause", false)
	h.events.WaitFor(t, "the pause report", func(event provider.Event) bool {
		upserted, ok := event.Body.(provider.EntryUpserted)
		return ok && upserted.Entry.Text == "Goal paused: ship it"
	})
}
