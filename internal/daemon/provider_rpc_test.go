package daemon

// Provider RPC tests: starting, signing in to and listing agents, their
// native sessions, and a draft's settings before a session exists.

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/Aqothy/jsonrpc2"
	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/provider/providertest"
)

func TestProviderStartAndList(t *testing.T) {
	s := newTestServer(t)
	client := newRecordingClient(t, s)
	if err := s.providerService.RegisterInstance(acpInstanceSpec("codex", "codex", fakeACPAgentCommand())); err != nil {
		t.Fatal(err)
	}
	var started provider.InstanceInfo
	client.call(t, wire.MethodProviderStart, wire.ProviderInstanceParams{InstanceID: "codex"}, &started)
	if started.InstanceID != "codex" || started.Driver != "acp" {
		t.Fatalf("started = %#v, want codex/acp", started)
	}
	if raw, err := json.Marshal(started); err != nil || strings.Contains(string(raw), `"command"`) || strings.Contains(string(raw), `"config"`) {
		t.Fatalf("provider info exposes its construction config: %s (%v)", raw, err)
	}
	var list []provider.InstanceInfo
	client.call(t, wire.MethodProviderList, nil, &list)
	listed := make(map[provider.InstanceID]provider.InstanceInfo, len(list))
	for _, instance := range list {
		listed[instance.InstanceID] = instance
	}
	if len(list) != 3 || listed["codex"].Status != provider.InstanceStatusInitialized ||
		listed["codex-app-server"].Driver != "codex-app-server" || listed["codex-app-server"].Status != provider.InstanceStatusConfigured ||
		listed["claude-code"].Driver != "claude-code" || listed["claude-code"].Status != provider.InstanceStatusConfigured {
		t.Fatalf("provider.list = %#v, want the started ACP agent and the configured Codex and Claude Code", list)
	}
}

// A client names an instance the daemon defines and can't define one: a
// spec sent along is not read, so nothing runs and nothing is listed.
func TestProviderStartRunsOnlyWhatTheDaemonDefines(t *testing.T) {
	s := newTestServer(t)
	client := newRecordingClient(t, s)
	pidPath := filepath.Join(t.TempDir(), "agent.pid")
	if err := client.callErr(wire.MethodProviderStart, map[string]any{
		"instanceId": "mine", "name": "mine", "driver": "acp",
		"config": map[string]any{"command": fakeACPAgentCommand("-pidfile", pidPath)},
	}, nil); err == nil {
		t.Fatal("provider.start with a client's spec succeeded")
	}
	if _, err := os.Stat(pidPath); !os.IsNotExist(err) {
		t.Fatalf("the client's command ran: %v", err)
	}
	var list []provider.InstanceInfo
	client.call(t, wire.MethodProviderList, nil, &list)
	if slices.ContainsFunc(list, func(info provider.InstanceInfo) bool { return info.InstanceID == "mine" }) {
		t.Fatalf("provider.list = %#v, want no instance a client defined", list)
	}
	if err := client.callErr(wire.MethodProviderStart, wire.ProviderInstanceParams{}, nil); err == nil {
		t.Fatal("provider.start without instanceId succeeded")
	}
}

func TestProviderAuthenticateAndLogout(t *testing.T) {
	s := newTestServer(t)
	client := newRecordingClient(t, s)
	started, err := startInstance(s, acpInstanceSpec("codex", "codex", fakeACPAgentCommand()))
	if err != nil {
		t.Fatal(err)
	}
	if started.Auth.Status != provider.AuthStatusUnknown || len(started.Auth.Methods) != 1 || started.Auth.Methods[0].ID != "agent-login" {
		t.Fatalf("auth = %#v, want unknown with the advertised agent-login", started.Auth)
	}
	if err := client.callErr(wire.MethodProviderAuthenticate, wire.ProviderAuthenticateParams{InstanceID: "codex", MethodID: "not-advertised"}, nil); err == nil {
		t.Fatal("authenticate with a method the agent didn't advertise succeeded")
	}
	var authenticated provider.AuthenticationResult
	client.call(t, wire.MethodProviderAuthenticate, wire.ProviderAuthenticateParams{InstanceID: "codex", MethodID: "agent-login"}, &authenticated)
	if authenticated.Instance.Auth.Status != provider.AuthStatusAuthenticated {
		t.Fatalf("auth after authenticate = %q", authenticated.Instance.Auth.Status)
	}
	var loggedOut provider.InstanceInfo
	client.call(t, wire.MethodProviderLogout, wire.ProviderInstanceParams{InstanceID: "codex"}, &loggedOut)
	if loggedOut.Auth.Status != provider.AuthStatusUnauthenticated {
		t.Fatalf("auth after logout = %q", loggedOut.Auth.Status)
	}
}

// An agent can ask a question while signing in, before any session exists
// (an ACP request-scoped elicitation). It goes to the client whose sign-in
// runs, and the answer reaches the agent before authenticate returns.
func TestProviderSignInQuestionReachesSigningInClient(t *testing.T) {
	s := newTestServer(t)
	client := newRecordingClient(t, s)
	startFakeACPAgent(t, s, "codex", "-ask-to-sign-in")
	signedIn := make(chan error, 1)
	var result provider.AuthenticationResult
	go func() {
		signedIn <- client.callErr(wire.MethodProviderAuthenticate, wire.ProviderAuthenticateParams{InstanceID: "codex", MethodID: "ask-login"}, &result)
	}()
	var question wire.ProviderQuestion
	client.waitFor(t, "the sign-in question", func() bool {
		if len(client.providerQuestions) > 0 {
			question = client.providerQuestions[0]
		}
		return len(client.providerQuestions) > 0
	})
	if question.InstanceID != "codex" || question.Request.Message != "Enter the code from your email." || len(question.Request.Questions) != 1 || question.Request.Questions[0].ID != "code" {
		t.Fatalf("question = %+v", question)
	}
	if err := client.callErr(wire.MethodProviderQuestionAnswer, wire.ProviderQuestionAnswerParams{RequestID: question.RequestID, ActionID: "approve", Answers: map[string][]string{"code": {"1234"}}}, nil); err == nil {
		t.Fatal("an answer with an action the question doesn't offer was taken")
	}
	client.call(t, wire.MethodProviderQuestionAnswer, wire.ProviderQuestionAnswerParams{RequestID: question.RequestID, ActionID: "accept", Answers: map[string][]string{"code": {"1234"}}}, nil)
	if err := <-signedIn; err != nil {
		t.Fatalf("authenticate: %v", err)
	}
	if result.Instance.Auth.Status != provider.AuthStatusAuthenticated {
		t.Fatalf("auth = %q, want authenticated", result.Instance.Auth.Status)
	}
}

// A message sent while a provider restarts waits for it: a turn started then
// would be cut off.
func TestAMessageSentDuringAProviderRestartWaitsForIt(t *testing.T) {
	s := newTestServer(t)
	client := newRecordingClient(t, s)
	startFakeACPAgent(t, s, "agent")
	thread := client.createThread(t, "agent", t.TempDir()).Thread
	client.subscribe(t, thread)

	var sent orchestration.DeliveryID
	s.restartProviderWhenIdle("agent", func(ctx context.Context) error {
		sent = client.deliver(t, thread, "hello").Delivery
		snapshot := client.subscribe(t, thread)
		if len(snapshot.Queue) != 1 || snapshot.Queue[0].State != orchestration.DeliveryQueued {
			t.Fatalf("during the restart the queue = %#v, want the message still queued", snapshot.Queue)
		}
		_, err := s.providerService.RestartInstance(ctx, "agent")
		return err
	})
	if turn := client.waitSettled(t, thread, sent); turn.State != provider.TurnCompleted {
		t.Fatalf("turn after the restart = %s", turn.State)
	}
}

func TestProviderSessionManagement(t *testing.T) {
	s := newTestServer(t)
	startFakeACPAgent(t, s, "agent")
	client := newRecordingClient(t, s)
	cwd := client.addProject(t, t.TempDir())
	thread := client.createThread(t, "agent", cwd).Thread
	client.subscribe(t, thread)
	client.waitSettled(t, thread, client.deliver(t, thread, "hello").Delivery)

	var sessions []wire.SessionSummary
	client.call(t, wire.MethodProviderListSessions, wire.ProviderListSessionsParams{InstanceID: "agent"}, &sessions)
	if len(sessions) != 1 || sessions[0].SessionID != "sess-1" || sessions[0].Cwd != cwd || sessions[0].Title != "Test session" || sessions[0].Thread != thread {
		t.Fatalf("provider.listSessions = %#v, want the chat's session, naming the chat", sessions)
	}
	err := client.callErr(wire.MethodProviderDeleteSession, wire.ProviderSessionParams{InstanceID: "agent", SessionID: "sess-1"}, nil)
	if err == nil || !strings.Contains(err.Error(), provider.ErrUnsupported.Error()) {
		t.Fatalf("deleting a session the agent can't delete = %v, want unsupported", err)
	}

	client.command(t, wire.CommandParams{DeleteThread: &orchestration.DeleteThread{Thread: thread}})
	var after []wire.SessionSummary
	client.call(t, wire.MethodProviderListSessions, wire.ProviderListSessionsParams{InstanceID: "agent"}, &after)
	if len(after) != 1 || after[0].SessionID != "sess-1" || after[0].Thread != "" {
		t.Fatalf("provider.listSessions after the chat was deleted = %#v, want its session, no chat's now", after)
	}
}

// Deleting the session a chat has open deletes the chat with it, so nothing
// is left on a session that is gone.
func TestDeletingASessionDeletesTheChatOnIt(t *testing.T) {
	s := newTestServer(t)
	startFakeACPAgent(t, s, "agent", "-delete")
	client := newRecordingClient(t, s)
	thread := client.createThread(t, "agent", t.TempDir()).Thread
	client.subscribe(t, thread)
	client.waitSettled(t, thread, client.deliver(t, thread, "hello").Delivery)

	client.call(t, wire.MethodProviderDeleteSession, wire.ProviderSessionParams{InstanceID: "agent", SessionID: "sess-1"}, nil)
	client.waitEvent(t, "the chat to be removed", func(event orchestration.ThreadEvent) bool {
		return event.Kind == orchestration.EventRemoved && event.Thread == thread
	})
	if _, err := client.commandErr(wire.CommandParams{Deliver: &orchestration.Deliver{Thread: thread, Body: orchestration.MessageBody{Text: "again"}}}); err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("a message to the deleted chat = %v, want not found", err)
	}
	var sessions []provider.SessionSummary
	client.call(t, wire.MethodProviderListSessions, wire.ProviderListSessionsParams{InstanceID: "agent"}, &sessions)
	if len(sessions) != 0 {
		t.Fatalf("sessions after the delete = %#v, want none", sessions)
	}
}

// What an agent can do is known once it runs: a delete that is the first
// call to it after a restart starts it and asks, as for a session no chat is
// on.
func TestDeletingAChatsSessionBeforeItsAgentRanSinceTheRestart(t *testing.T) {
	dir := t.TempDir()
	s := newTestServerAt(t, dir)
	startFakeACPAgent(t, s, "agent", "-delete")
	client := newRecordingClient(t, s)
	thread := client.createThread(t, "agent", t.TempDir()).Thread
	client.subscribe(t, thread)
	client.waitSettled(t, thread, client.deliver(t, thread, "hello").Delivery)
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	again := newTestServerAt(t, dir)
	if err := again.providerService.RegisterInstance(acpInstanceSpec("agent", "agent", fakeACPAgentCommand("-delete"))); err != nil {
		t.Fatal(err)
	}
	restarted := newRecordingClient(t, again)
	restarted.call(t, wire.MethodProviderDeleteSession, wire.ProviderSessionParams{InstanceID: "agent", SessionID: "sess-1"}, nil)
	if _, err := restarted.commandErr(wire.CommandParams{Deliver: &orchestration.Deliver{Thread: thread, Body: orchestration.MessageBody{Text: "again"}}}); err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("a message to the deleted chat = %v, want not found", err)
	}
}

func TestDeletingASessionNoChatIsOn(t *testing.T) {
	s := newTestServer(t)
	startFakeACPAgent(t, s, "agent", "-delete")
	client := newRecordingClient(t, s)
	thread := client.createThread(t, "agent", t.TempDir()).Thread
	client.subscribe(t, thread)
	client.waitSettled(t, thread, client.deliver(t, thread, "hello").Delivery)
	client.command(t, wire.CommandParams{DeleteThread: &orchestration.DeleteThread{Thread: thread}})

	client.call(t, wire.MethodProviderDeleteSession, wire.ProviderSessionParams{InstanceID: "agent", SessionID: "sess-1"}, nil)
	var sessions []provider.SessionSummary
	client.call(t, wire.MethodProviderListSessions, wire.ProviderListSessionsParams{InstanceID: "agent"}, &sessions)
	if len(sessions) != 0 {
		t.Fatalf("sessions after the delete = %#v, want none", sessions)
	}
}

// An ACP agent's exit closes its sessions before the process is said gone,
// so each ends with its own reason.
func TestACPAgentExitIsReportedAfterItsSessionsClose(t *testing.T) {
	events := providertest.NewRecorder()
	spec := acpInstanceSpec("agent", "Agent", fakeACPAgentCommand())
	instance, err := drivers[spec.Driver].Open(context.Background(), spec, provider.Host{Emit: events.Emit, Exited: events.Exited})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = instance.Close() })
	opened, err := instance.Open(context.Background(), provider.OpenInput{Workspace: provider.Workspace{Cwd: t.TempDir()}})
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Kill(instance.Info().PID, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	var before []provider.Event
	waitUntil(t, "the agent's exit to be reported", func() bool {
		var exited bool
		before, exited = events.BeforeExit()
		return exited
	})
	if !slices.ContainsFunc(before, func(event provider.Event) bool {
		_, closed := event.Body.(provider.SessionClosed)
		return closed && event.Session == opened.Session
	}) {
		t.Fatalf("events before the exit = %#v, want the session's close among them", before)
	}
}

func TestRPCErrorPreservesAgentRequestError(t *testing.T) {
	err := rpcError(&provider.RequestError{Code: -32000, Message: "Authentication required", Data: json.RawMessage(`{"method":"login"}`)})
	var wireErr *jsonrpc2.WireError
	if !errors.As(err, &wireErr) || wireErr.Code != -32000 || wireErr.Message != "Authentication required" || string(wireErr.Data) != `{"method":"login"}` {
		t.Fatalf("rpcError = %#v", err)
	}
}

// testDriver serves testInstances by instance ID, so a test can reach the
// instance the daemon runs.
const testDriver provider.DriverKind = "test"

type testInstances struct {
	mu        sync.Mutex
	instances map[provider.InstanceID]*testInstance
}

func newTestInstances(ids ...provider.InstanceID) *testInstances {
	set := &testInstances{instances: make(map[provider.InstanceID]*testInstance)}
	for _, id := range ids {
		set.instances[id] = &testInstance{
			info:      provider.InstanceInfo{InstanceID: id, Name: string(id), Driver: testDriver, Status: provider.InstanceStatusInitialized},
			callbacks: make(map[string]provider.OptionsSessionCallbacks),
			closed:    make(chan string, 8),
		}
	}
	return set
}

func (set *testInstances) driver() map[provider.DriverKind]provider.Driver {
	return map[provider.DriverKind]provider.Driver{testDriver: {
		Open: func(_ context.Context, spec provider.InstanceSpec, _ provider.Host) (provider.Instance, error) {
			set.mu.Lock()
			defer set.mu.Unlock()
			return set.instances[spec.InstanceID], nil
		},
		Static: func(spec provider.InstanceSpec) provider.InstanceInfo {
			return provider.InstanceInfo{InstanceID: spec.InstanceID, Name: spec.Name, Driver: testDriver}
		},
	}}
}

// testInstance has a draft's settings and suggests /review's input.
type testInstance struct {
	provider.Unsupported
	mu        sync.Mutex
	info      provider.InstanceInfo
	opens     int
	callbacks map[string]provider.OptionsSessionCallbacks
	// closeBlock, while set, holds CloseOptions.
	closeBlock chan struct{}
	closed     chan string
}

func (i *testInstance) Info() provider.InstanceInfo { return i.info }
func (i *testInstance) Close() error                { return nil }

func (i *testInstance) CompleteCommand(_ context.Context, in provider.CompleteCommandInput) ([]provider.CommandCompletion, error) {
	if in.Command != "review" {
		return nil, nil
	}
	return []provider.CommandCompletion{{Input: in.Input + "main", Label: "main", Description: in.Cwd}}, nil
}

func (i *testInstance) OpenOptions(_ context.Context, cwd string, callbacks provider.OptionsSessionCallbacks) (provider.OptionsSession, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.opens++
	handle := "handle-" + cwd
	i.callbacks[handle] = callbacks
	return provider.OptionsSession{
		Handle:        handle,
		ConfigOptions: []provider.ConfigOption{{ID: "model", Type: provider.ConfigOptionTypeSelect, Category: provider.ConfigOptionCategoryModel, CurrentValue: "fast"}},
		Skills:        []provider.Skill{{Name: "review", ShortDescription: "Review changes", Path: "/skills/review", Scope: "user", Enabled: true}},
	}, nil
}

func (i *testInstance) SetOption(_ context.Context, _, option string, value any) ([]provider.ConfigOption, error) {
	return []provider.ConfigOption{{ID: option, Type: provider.ConfigOptionTypeSelect, Category: provider.ConfigOptionCategoryModel, CurrentValue: value}}, nil
}

func (i *testInstance) CloseOptions(ctx context.Context, handle string) error {
	i.mu.Lock()
	block := i.closeBlock
	i.mu.Unlock()
	if block != nil {
		select {
		case <-block:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	i.mu.Lock()
	delete(i.callbacks, handle)
	i.mu.Unlock()
	i.closed <- handle
	return nil
}

func (i *testInstance) openCount() int {
	i.mu.Lock()
	defer i.mu.Unlock()
	return i.opens
}

func (i *testInstance) callback(handle string) provider.OptionsSessionCallbacks {
	i.mu.Lock()
	defer i.mu.Unlock()
	return i.callbacks[handle]
}

func startTestInstances(t *testing.T, s *Server, set *testInstances) {
	t.Helper()
	for id := range set.instances {
		if _, err := startInstance(s, provider.InstanceSpec{InstanceID: id, Name: string(id), Driver: testDriver}); err != nil {
			t.Fatalf("start %s: %v", id, err)
		}
	}
}

// A draft's settings session stays warm per agent while its folder is the
// same, is replaced (without waiting on the old one's close) when it moves,
// routes the agent's own changes to the client, and closes with the client.
func TestProviderOptionsSessionsStayWarmAndReplaceByCwd(t *testing.T) {
	set := newTestInstances("a", "b")
	s := newTestServerWith(t, t.TempDir(), set.driver())
	startTestInstances(t, s, set)
	a, b := set.instances["a"], set.instances["b"]
	client := newRecordingClient(t, s)
	get := func(instance provider.InstanceID, cwd string) wire.ProviderOptionsResult {
		t.Helper()
		var result wire.ProviderOptionsResult
		client.call(t, wire.MethodProviderOptionsGet, wire.ProviderOptionsGetParams{ProviderInstanceID: instance, Cwd: cwd}, &result)
		// Only opening returns skills; every other result keeps them.
		if len(result.Skills) != 1 || result.Skills[0].Name != "review" {
			t.Fatalf("skills = %#v, want review", result.Skills)
		}
		return result
	}

	// A settings session runs the agent in its folder, so it is held to the
	// project rule.
	var refused wire.ProviderOptionsResult
	err := client.callErr(wire.MethodProviderOptionsGet, wire.ProviderOptionsGetParams{ProviderInstanceID: "a", Cwd: t.TempDir()}, &refused)
	if code, _ := commandCode(err); code != invalidParamsCode || a.openCount() != 0 {
		t.Fatalf("settings outside a project = %v with %d sessions opened, want invalid params and none", err, a.openCount())
	}
	project := client.addProject(t, t.TempDir())
	folder := func(name string) string {
		t.Helper()
		path := filepath.Join(project, name)
		if err := os.Mkdir(path, 0o755); err != nil {
			t.Fatal(err)
		}
		return path
	}
	firstDir, otherDir, secondDir := folder("first"), folder("other"), folder("second")

	first := get("a", firstDir)
	get("b", otherDir)
	if reused := get("a", firstDir); reused.OptionsSessionID != first.OptionsSessionID || a.openCount() != 1 || b.openCount() != 1 {
		t.Fatalf("switching back opened another session: %#v then %#v", first, reused)
	}
	a.callback("handle-" + firstDir).Updated([]provider.ConfigOption{{ID: "model", Type: provider.ConfigOptionTypeSelect, CurrentValue: "slow"}})
	client.waitFor(t, "the agent's own change", func() bool {
		return slices.ContainsFunc(client.optionsUpdates, func(update wire.ProviderOptionsResult) bool {
			return update.OptionsSessionID == first.OptionsSessionID && update.ConfigOptions[0].CurrentValue == "slow" && len(update.Skills) == 1
		})
	})
	var set1 wire.ProviderOptionsResult
	client.call(t, wire.MethodProviderOptionsSet, wire.ProviderOptionsSetParams{OptionsSessionID: first.OptionsSessionID, OptionID: "model", Value: "fast"}, &set1)
	if len(set1.Skills) != 1 || set1.ConfigOptions[0].CurrentValue != "fast" {
		t.Fatalf("set = %#v", set1)
	}

	block := make(chan struct{})
	a.mu.Lock()
	a.closeBlock = block
	a.mu.Unlock()
	replacement := get("a", secondDir)
	if replacement.OptionsSessionID == first.OptionsSessionID {
		t.Fatal("moving the draft's folder kept the old settings session")
	}
	close(block)
	if handle := <-a.closed; handle != "handle-"+firstDir {
		t.Fatalf("closed %q, want the old session", handle)
	}

	a.callback("handle-" + secondDir).Invalidated()
	client.waitFor(t, "the invalidation", func() bool {
		return slices.Contains(client.optionsInvalidated, wire.ProviderOptionsInvalidated{OptionsSessionID: replacement.OptionsSessionID})
	})
	if err := client.callErr(wire.MethodProviderOptionsSet, wire.ProviderOptionsSetParams{OptionsSessionID: replacement.OptionsSessionID, OptionID: "model", Value: "slow"}, nil); err == nil {
		t.Fatal("setting an invalidated session succeeded")
	}
	if reopened := get("a", secondDir); reopened.OptionsSessionID == replacement.OptionsSessionID {
		t.Fatal("an invalidated session was reused")
	}

	_ = client.conn.Close()
	closed := map[string]bool{}
	for range 2 {
		select {
		case handle := <-a.closed:
			closed["a "+handle] = true
		case handle := <-b.closed:
			closed["b "+handle] = true
		case <-time.After(5 * time.Second):
			t.Fatalf("closed %v on disconnect, want each agent's session", closed)
		}
	}
	if !closed["a handle-"+secondDir] || !closed["b handle-"+otherDir] {
		t.Fatalf("closed %v on disconnect", closed)
	}
}

// provider.completeCommand asks the chat's agent, in the chat's workspace,
// and always answers an array.
func TestCompleteCommandAsksTheChatsAgent(t *testing.T) {
	set := newTestInstances("agent")
	s := newTestServerWith(t, t.TempDir(), set.driver())
	startTestInstances(t, s, set)
	client := newRecordingClient(t, s)
	cwd := client.addProject(t, t.TempDir())
	thread := client.createThread(t, "agent", cwd).Thread

	var completions []wire.CommandCompletion
	client.call(t, wire.MethodProviderCompleteCommand, wire.ProviderCompleteCommandParams{Thread: thread, Command: "review", Input: "--base "}, &completions)
	if want := []wire.CommandCompletion{{Input: "--base main", Label: "main", Description: cwd}}; !slices.Equal(completions, want) {
		t.Fatalf("completions = %#v, want %#v", completions, want)
	}
	var none json.RawMessage
	client.call(t, wire.MethodProviderCompleteCommand, wire.ProviderCompleteCommandParams{Thread: thread, Command: "goal"}, &none)
	if string(none) != "[]" {
		t.Fatalf("no completions = %s, want []", none)
	}
	err := client.callErr(wire.MethodProviderCompleteCommand, wire.ProviderCompleteCommandParams{Thread: "missing", Command: "review"}, &none)
	if code, reason := commandCode(err); code != commandRefusedCode || reason != orchestration.CodeNotFound {
		t.Fatalf("completing in a missing chat = %v, want refused not found", err)
	}
}
