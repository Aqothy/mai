package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Aqothy/jsonrpc2"
	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/providerservice"
)

func TestRunWebSocketDoesNotStartAfterServerClosed(t *testing.T) {
	s := newTestServer(t)
	if err := s.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	done := make(chan error, 1)
	go func() { done <- s.RunWebSocket("127.0.0.1:0") }()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("RunWebSocket after Close: %v", err)
		}
	case <-time.After(250 * time.Millisecond):
		// Close has already completed, so release a listener started by the
		// broken implementation directly before failing the regression test.
		s.mu.Lock()
		httpServer := s.httpServer
		s.mu.Unlock()
		if httpServer != nil {
			_ = httpServer.Close()
		}
		<-done
		t.Fatal("RunWebSocket started listening after Server.Close completed")
	}
}

func installForkRPCProvider(t *testing.T, s *Server, adapter *optionsRPCProvider, cwd string) {
	t.Helper()
	s.providerService.Close()
	s.providerService = providerservice.New(func(context.Context, provider.InstanceSpec, provider.RuntimeEventListener) (providerservice.ProviderInstance, error) {
		return adapter, nil
	})
	if _, err := s.providerService.StartInstance(context.Background(), provider.InstanceSpec{InstanceID: adapter.info.InstanceID, Driver: "test", Name: "Fork test"}, false); err != nil {
		t.Fatalf("start fork provider: %v", err)
	}
	if err := s.providerService.RegisterImportedSession("source", adapter.info.InstanceID, "native-source", provider.StartSessionInput{ThreadID: "source", ProviderInstanceID: adapter.info.InstanceID, Cwd: cwd}); err != nil {
		t.Fatalf("register source route: %v", err)
	}
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadCreate, ThreadID: "source", Cwd: cwd}); err != nil {
		t.Fatalf("create source thread: %v", err)
	}
}

func newForkRPCProvider() *optionsRPCProvider {
	return &optionsRPCProvider{info: provider.InstanceInfo{
		InstanceID: "fork-provider",
		Status:     provider.InstanceStatusInitialized,
		Capabilities: provider.Capabilities{
			Fork:          true,
			SessionDelete: true,
			LoadReplay:    true,
		},
	}}
}

func TestForkProviderThreadPreflightsPersistenceAndActiveTurn(t *testing.T) {
	t.Run("persistence unavailable", func(t *testing.T) {
		s := newServer(newLoggerFromEnv(), nil)
		defer s.Close()
		adapter := newForkRPCProvider()
		installForkRPCProvider(t, s, adapter, t.TempDir())

		if _, _, err := s.ForkProviderThread(context.Background(), "source"); err == nil {
			t.Fatal("fork without persistence succeeded")
		}
		if adapter.forkCalls != 0 {
			t.Fatalf("native fork calls = %d, want none", adapter.forkCalls)
		}
	})

	t.Run("turn running", func(t *testing.T) {
		s := newTestServer(t)
		defer s.Close()
		adapter := newForkRPCProvider()
		installForkRPCProvider(t, s, adapter, t.TempDir())
		if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{
			Type:               orchestration.CommandThreadTurnStart,
			ThreadID:           "source",
			ProviderInstanceID: adapter.info.InstanceID,
			Message:            &orchestration.CommandMessage{Text: "still working"},
		}); err != nil {
			t.Fatalf("start source turn: %v", err)
		}

		if _, _, err := s.ForkProviderThread(context.Background(), "source"); err == nil {
			t.Fatal("fork while turn was running succeeded")
		}
		if adapter.forkCalls != 0 {
			t.Fatalf("native fork calls = %d, want none", adapter.forkCalls)
		}
	})
}

func TestForkProviderThreadDeletesUnpersistedNativeFork(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	adapter := newForkRPCProvider()
	adapter.forkSummary = provider.SessionSummary{SessionID: "native-fork", Cwd: "relative-path"}
	adapter.deleted = make(chan string, 1)
	installForkRPCProvider(t, s, adapter, t.TempDir())

	if _, _, err := s.ForkProviderThread(context.Background(), "source"); err == nil {
		t.Fatal("fork with invalid imported cwd succeeded")
	}
	select {
	case sessionID := <-adapter.deleted:
		if sessionID != "native-fork" {
			t.Fatalf("deleted session = %q, want native-fork", sessionID)
		}
	default:
		t.Fatal("unpersisted native fork was not deleted")
	}
}

func TestForkProviderThreadCarriesSourceSettings(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	adapter := newForkRPCProvider()
	adapter.forkSummary = provider.SessionSummary{SessionID: "native-fork"}
	cwd := t.TempDir()
	installForkRPCProvider(t, s, adapter, cwd)
	if err := s.metadataStore.SaveInstance(provider.InstanceSpec{InstanceID: adapter.info.InstanceID, Driver: "test", Name: "Fork test"}); err != nil {
		t.Fatalf("SaveInstance: %v", err)
	}
	// The source was started from a draft at Luna/Low; route preferences are
	// what the source itself would resume with.
	sourceSettings := []provider.ConfigOptionSelection{
		{OptionID: "model", Value: "gpt-6-luna", Category: provider.ConfigOptionCategoryModel},
		{OptionID: "reasoning_effort", Value: "low", Category: provider.ConfigOptionCategoryThoughtLevel},
	}
	if _, err := s.providerService.StartSession(context.Background(), "source", provider.StartSessionInput{
		ProviderInstanceID: adapter.info.InstanceID, Cwd: cwd,
		ModelSelection:   &provider.ModelSelection{Model: "gpt-6-luna"},
		ConfigSelections: sourceSettings,
	}); err != nil {
		t.Fatalf("start source session: %v", err)
	}

	forkID, imported, err := s.ForkProviderThread(context.Background(), "source")
	if err != nil || !imported {
		t.Fatalf("ForkProviderThread = %q, %v, %v", forkID, imported, err)
	}
	entry, ok := s.orchestration.ThreadListEntry(forkID)
	if !ok || entry.ModelSelection == nil || entry.ModelSelection.Model != "gpt-6-luna" {
		t.Fatalf("fork thread model = %#v, want source model", entry.ModelSelection)
	}
	routes, err := s.metadataStore.LoadRoutes()
	if err != nil {
		t.Fatalf("LoadRoutes: %v", err)
	}
	if got := routes[string(forkID)].StartInput.ConfigSelections; !reflect.DeepEqual(got, sourceSettings) {
		t.Fatalf("persisted fork config selections = %#v, want %#v", got, sourceSettings)
	}

	// Opening the fork resumes its native session with the source settings,
	// even though the fresh projection only carries the model.
	if _, err := s.providerService.StartSession(context.Background(), string(forkID), provider.StartSessionInput{
		ProviderInstanceID: adapter.info.InstanceID, Cwd: cwd,
		ModelSelection: &provider.ModelSelection{Model: "gpt-6-luna"}, ReplayHistory: true,
	}); err != nil {
		t.Fatalf("open fork: %v", err)
	}
	adapter.mu.Lock()
	resume := adapter.starts[len(adapter.starts)-1]
	adapter.mu.Unlock()
	if resume.ProviderSessionID != "native-fork" || !reflect.DeepEqual(resume.ConfigSelections, sourceSettings) {
		t.Fatalf("fork resume input = %#v, want native-fork with source settings", resume)
	}
}

func TestProviderOptionsSessionsStayWarmAndReplaceByCwd(t *testing.T) {
	s := newTestServer(t)
	s.providerService.Close()
	instances := map[provider.InstanceID]*optionsRPCProvider{}
	for _, instanceID := range []provider.InstanceID{"provider-a", "provider-b"} {
		instances[instanceID] = &optionsRPCProvider{
			info: provider.InstanceInfo{
				InstanceID: instanceID, Name: string(instanceID), Status: provider.InstanceStatusInitialized,
				Capabilities: provider.Capabilities{ConfigOptions: true},
			},
			sessions:  make(map[string][]provider.ConfigOption),
			callbacks: make(map[string]provider.OptionsSessionCallbacks),
			closed:    make(chan string, 4),
		}
	}
	s.providerService = providerservice.New(func(_ context.Context, spec provider.InstanceSpec, _ provider.RuntimeEventListener) (providerservice.ProviderInstance, error) {
		return instances[spec.InstanceID], nil
	})
	for instanceID := range instances {
		if _, err := s.providerService.StartInstance(context.Background(), provider.InstanceSpec{
			InstanceID: instanceID, Name: string(instanceID), Driver: "test",
		}, false); err != nil {
			t.Fatalf("start %s: %v", instanceID, err)
		}
	}
	defer s.Close()

	client := &rpcClient{
		id: "options-client", logger: s.logger, outbound: make(chan rpcOutbound, 8),
		done: make(chan struct{}), threadSubscriptions: make(map[orchestration.ThreadID]struct{}),
	}
	handler := &rpcHandler{server: s, client: client}
	get := func(instanceID provider.InstanceID, cwd string) wire.ProviderOptionsResult {
		t.Helper()
		result, err := handler.getProviderOptions(context.Background(), wire.ProviderOptionsGetParams{ProviderInstanceID: instanceID, Cwd: cwd})
		if err != nil {
			t.Fatalf("get %s %s: %v", instanceID, cwd, err)
		}
		return result
	}
	// Every result path (open, warm reuse, update, set) re-attaches the
	// session's skills, which only the open call returns from the provider.
	requireSkills := func(label string, skills []provider.Skill) {
		t.Helper()
		if len(skills) != 1 || skills[0].Name != "review" {
			t.Fatalf("%s skills = %#v, want review", label, skills)
		}
	}
	first := get("provider-a", "/first")
	requireSkills("first", first.Skills)
	get("provider-b", "/other")
	reused := get("provider-a", "/first")
	if reused.OptionsSessionID != first.OptionsSessionID ||
		instances["provider-a"].openCount() != 1 ||
		instances["provider-b"].openCount() != 1 {
		t.Fatalf("warm switch-back opened another session: first=%#v reused=%#v", first, reused)
	}
	requireSkills("reused", reused.Skills)
	instances["provider-a"].publishOptions("handle-/first", []provider.ConfigOption{{
		ID: "model", Type: provider.ConfigOptionTypeSelect, CurrentValue: "slow",
	}})
	select {
	case message := <-client.outbound:
		update, ok := message.params.(wire.ProviderOptionsResult)
		if message.method != wire.MethodProviderOptionsUpdated ||
			!ok ||
			update.OptionsSessionID != first.OptionsSessionID ||
			len(update.ConfigOptions) != 1 ||
			update.ConfigOptions[0].CurrentValue != "slow" {
			t.Fatalf("options update notification = %#v", message)
		}
		requireSkills("update", update.Skills)
	case <-time.After(2 * time.Second):
		t.Fatal("spontaneous options update was not routed to the client")
	}
	setResult, err := handler.setProviderOption(context.Background(), wire.ProviderOptionsSetParams{
		OptionsSessionID: first.OptionsSessionID, OptionID: "model", Value: "fast",
	})
	if err != nil {
		t.Fatalf("set provider option: %v", err)
	}
	requireSkills("set", setResult.Skills)

	closeStarted := make(chan struct{}, 1)
	closeBlock := make(chan struct{})
	releaseClose := sync.OnceFunc(func() { close(closeBlock) })
	t.Cleanup(releaseClose)
	instances["provider-a"].mu.Lock()
	instances["provider-a"].closeStarted = closeStarted
	instances["provider-a"].closeBlock = closeBlock
	instances["provider-a"].mu.Unlock()
	type replacementResult struct {
		result wire.ProviderOptionsResult
		err    error
	}
	replacementDone := make(chan replacementResult, 1)
	go func() {
		result, err := handler.getProviderOptions(context.Background(), wire.ProviderOptionsGetParams{
			ProviderInstanceID: "provider-a", Cwd: "/second",
		})
		replacementDone <- replacementResult{result: result, err: err}
	}()
	select {
	case <-closeStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("replacement did not begin closing the old options session")
	}
	var replacement wire.ProviderOptionsResult
	select {
	case result := <-replacementDone:
		if result.err != nil {
			t.Fatalf("replacement get: %v", result.err)
		}
		if result.result.OptionsSessionID == first.OptionsSessionID {
			t.Fatal("cwd replacement reused the old options ID")
		}
		replacement = result.result
	case <-time.After(2 * time.Second):
		t.Fatal("replacement waited for best-effort close of the old options session")
	}
	releaseClose()
	select {
	case handle := <-instances["provider-a"].closed:
		if handle != "handle-/first" {
			t.Fatalf("closed handle = %q, want old provider-a handle", handle)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("old provider-a options session was not closed")
	}
	if instances["provider-a"].openCount() != 2 || instances["provider-b"].openCount() != 1 {
		t.Fatal("cwd replacement affected the wrong provider")
	}

	instances["provider-a"].invalidateOptions("handle-/second")
	select {
	case message := <-client.outbound:
		invalidation, ok := message.params.(wire.ProviderOptionsInvalidated)
		if message.method != wire.MethodProviderOptionsInvalidated ||
			!ok ||
			invalidation.OptionsSessionID != replacement.OptionsSessionID {
			t.Fatalf("options invalidation notification = %#v", message)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("options invalidation was not routed to the client")
	}
	if _, err := handler.setProviderOption(context.Background(), wire.ProviderOptionsSetParams{
		OptionsSessionID: replacement.OptionsSessionID, OptionID: "model", Value: "slow",
	}); err == nil {
		t.Fatal("set with invalidated optionsSessionId succeeded")
	}
	if reopened := get("provider-a", "/second"); reopened.OptionsSessionID == replacement.OptionsSessionID {
		t.Fatalf("reopen invalidated provider-a session = %#v", reopened)
	}
	s.disconnectRPCClient(client)
	for instanceID, wantHandle := range map[provider.InstanceID]string{
		"provider-a": "handle-/second",
		"provider-b": "handle-/other",
	} {
		select {
		case handle := <-instances[instanceID].closed:
			if handle != wantHandle {
				t.Fatalf("%s closed handle = %q, want %q", instanceID, handle, wantHandle)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("%s options session was not closed on disconnect", instanceID)
		}
	}
}

type optionsRPCProvider struct {
	mu           sync.Mutex
	info         provider.InstanceInfo
	opens        int
	sessions     map[string][]provider.ConfigOption
	callbacks    map[string]provider.OptionsSessionCallbacks
	closeStarted chan struct{}
	closeBlock   <-chan struct{}
	closed       chan string
	forkCalls    int
	forkSummary  provider.SessionSummary
	deleted      chan string
	starts       []provider.StartSessionInput
}

func (p *optionsRPCProvider) Info() provider.InstanceInfo { return p.info }
func (p *optionsRPCProvider) Close() error                { return nil }
func (p *optionsRPCProvider) StartSession(_ context.Context, input provider.StartSessionInput) (provider.StartSessionResult, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.starts = append(p.starts, input)
	return provider.StartSessionResult{Session: provider.Session{ProviderSessionID: input.ProviderSessionID}}, nil
}
func (p *optionsRPCProvider) SendTurn(context.Context, provider.SendTurnInput) error { return nil }
func (p *optionsRPCProvider) InterruptTurn(context.Context, provider.InterruptTurnInput) error {
	return nil
}
func (p *optionsRPCProvider) SetConfigOption(context.Context, provider.SetConfigOptionInput) error {
	return nil
}
func (p *optionsRPCProvider) RespondToRequest(context.Context, provider.RespondToRequestInput) error {
	return nil
}
func (p *optionsRPCProvider) StopSession(context.Context, provider.StopSessionInput) error {
	return nil
}
func (p *optionsRPCProvider) ListSessions(context.Context, string) ([]provider.SessionSummary, error) {
	return nil, nil
}
func (p *optionsRPCProvider) DeleteSession(_ context.Context, sessionID string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.deleted != nil {
		p.deleted <- sessionID
	}
	return nil
}
func (p *optionsRPCProvider) CloseSession(context.Context, string) error { return nil }
func (p *optionsRPCProvider) ForkSession(context.Context, provider.ForkSessionInput) (provider.ForkSessionResult, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.forkCalls++
	return provider.ForkSessionResult{Summary: p.forkSummary}, nil
}
func (p *optionsRPCProvider) OpenOptionsSession(_ context.Context, cwd string, callbacks provider.OptionsSessionCallbacks) (provider.OptionsSession, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.opens++
	handle := "handle-" + cwd
	options := []provider.ConfigOption{{
		ID: "model", Type: provider.ConfigOptionTypeSelect, Category: provider.ConfigOptionCategoryModel,
		Choices: []provider.ConfigChoice{{Value: "fast"}}, CurrentValue: "fast",
	}}
	p.sessions[handle] = options
	p.callbacks[handle] = callbacks
	return provider.OptionsSession{
		Handle: handle, ConfigOptions: options,
		Skills: []provider.Skill{{Name: "review", ShortDescription: "Review changes", Path: "/skills/review", Scope: "user", Enabled: true}},
	}, nil
}
func (p *optionsRPCProvider) SetOptionsSessionValue(_ context.Context, handle string, _ string, _ any) ([]provider.ConfigOption, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]provider.ConfigOption(nil), p.sessions[handle]...), nil
}
func (p *optionsRPCProvider) CloseOptionsSession(ctx context.Context, handle string) error {
	p.mu.Lock()
	closeStarted := p.closeStarted
	closeBlock := p.closeBlock
	p.mu.Unlock()
	if closeStarted != nil {
		select {
		case closeStarted <- struct{}{}:
		default:
		}
	}
	if closeBlock != nil {
		select {
		case <-closeBlock:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	delete(p.sessions, handle)
	delete(p.callbacks, handle)
	if p.closed != nil {
		select {
		case p.closed <- handle:
		default:
		}
	}
	return nil
}
func (p *optionsRPCProvider) openCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.opens
}

func (p *optionsRPCProvider) publishOptions(handle string, options []provider.ConfigOption) {
	p.mu.Lock()
	callback := p.callbacks[handle].Updated
	p.mu.Unlock()
	if callback != nil {
		callback(options)
	}
}

func (p *optionsRPCProvider) invalidateOptions(handle string) {
	p.mu.Lock()
	callback := p.callbacks[handle].Invalidated
	p.mu.Unlock()
	if callback != nil {
		callback()
	}
}

// registerTestRPCClient installs an in-memory client whose notifications land
// in its outbound channel synchronously with engine fan-out. Callers close the
// server via t.Cleanup registered first, so the client is removed before
// Server.Close tries to close its (absent) connection.
func registerTestRPCClient(t *testing.T, s *Server, id string) *rpcClient {
	t.Helper()
	client := &rpcClient{id: id, outbound: make(chan rpcOutbound, 8), done: make(chan struct{}), threadSubscriptions: make(map[orchestration.ThreadID]struct{})}
	s.rpcMu.Lock()
	s.rpcClients[client.id] = client
	s.rpcMu.Unlock()
	t.Cleanup(func() {
		s.rpcMu.Lock()
		delete(s.rpcClients, client.id)
		s.rpcMu.Unlock()
		client.closeOutbound()
	})
	return client
}

func handleThreadCall(handler *rpcHandler, method string, threadID orchestration.ThreadID) (any, error) {
	req, err := jsonrpc2.NewCall(jsonrpc2.StringID("1"), method, orchestration.SubscribeThreadInput{ThreadID: threadID})
	if err != nil {
		return nil, err
	}
	return handler.Handle(context.Background(), req)
}

func TestRPCUnsubscribeThreadStopsNotifications(t *testing.T) {
	s := newTestServer(t)
	t.Cleanup(func() { _ = s.Close() })
	client := registerTestRPCClient(t, s, "client-unsubscribe")
	handler := &rpcHandler{server: s, client: client}
	threadID := orchestration.ThreadID("thread-unsubscribe")
	// Engine listeners (including client fan-out) run before Dispatch returns,
	// so outbound state is settled after each dispatch below.
	dispatchTitle := func(commandType string, title string) {
		t.Helper()
		if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: commandType, CommandID: orchestration.CommandID("cmd-" + title), ThreadID: threadID, Title: title}); err != nil {
			t.Fatalf("%s: %v", commandType, err)
		}
	}
	expectNotification := func(want bool, when string) {
		t.Helper()
		select {
		case msg := <-client.outbound:
			if !want {
				t.Fatalf("unexpected %s notification %s", msg.method, when)
			}
		default:
			if want {
				t.Fatalf("expected a live event %s", when)
			}
		}
	}

	// A failed subscribe to a missing thread must not leave a live listener
	// behind for a thread later created under that id.
	if _, err := handleThreadCall(handler, wire.MethodOrchestrationSubscribeThread, threadID); err == nil {
		t.Fatal("subscribeThread missing thread err = nil, want error")
	}
	dispatchTitle(orchestration.CommandThreadCreate, "before")
	expectNotification(false, "after a failed subscribe")

	if _, err := handleThreadCall(handler, wire.MethodOrchestrationSubscribeThread, threadID); err != nil {
		t.Fatalf("subscribeThread: %v", err)
	}
	dispatchTitle(orchestration.CommandThreadMetaUpdate, "while-subscribed")
	expectNotification(true, "while subscribed")

	if _, err := handleThreadCall(handler, wire.MethodOrchestrationUnsubscribeThread, threadID); err != nil {
		t.Fatalf("unsubscribeThread: %v", err)
	}
	dispatchTitle(orchestration.CommandThreadMetaUpdate, "after-unsubscribe")
	expectNotification(false, "after unsubscribe")
}

// TestRPCOrchestrationApprovalRespondHonorsExplicitOption sends an accept
// decision together with an explicit optionId for a reject option. The
// scripted agent echoes the option it received, proving the selected option —
// not the kind-mapped decision — reaches the agent.
func TestRPCOrchestrationApprovalRespondHonorsExplicitOption(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("codex", "codex", helperCommand("scripted-sessions")), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}

	client := newRecordingClient(t, s)
	threadID := orchestration.ThreadID("thread-permission-option")

	client.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-create-perm-option", ThreadID: threadID, Title: "Permission option thread", ProviderInstanceID: "codex", Cwd: t.TempDir()})
	client.subscribeThread(t, threadID)
	client.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-turn-perm-option", ThreadID: threadID, Message: &orchestration.CommandMessage{MessageID: "msg-perm-option", Text: "permission"}})

	approvalEvent := client.waitForThreadEvent(t, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadApprovalOpened && event.Payload.Approval != nil
	})
	client.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadApprovalRespond, CommandID: "cmd-approval-option", ThreadID: threadID, RequestID: orchestration.ApprovalID(approvalEvent.Payload.Approval.RequestID), Decision: provider.ApprovalDecisionAccept, OptionID: "reject"})

	resolved := client.waitForThreadEvent(t, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadApprovalResolved && event.Payload.Approval != nil
	})
	// The resolved decision derives from the option the agent actually
	// received, so the accept decision must come back as decline.
	if resolved.Payload.Approval.OptionID != "reject" || resolved.Payload.Approval.Decision != provider.ApprovalDecisionDecline {
		t.Fatalf("resolved = %#v, want the explicitly selected reject option", resolved.Payload.Approval)
	}
	client.waitForThreadEvent(t, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadMessageSent && strings.Contains(event.Payload.Text, "perm:reject")
	})
}

func TestRPCOrchestrationDispatchRejectsInternalCommands(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	events := observeServerEvents(t, s)
	client := newRecordingClient(t, s)

	threadID := orchestration.ThreadID("thread-reject-internal")
	client.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-create-reject-internal", ThreadID: threadID, Title: "Reject internal", ProviderInstanceID: "codex"})

	// Provider/server event types are not commands: dispatching an event-shaped
	// name (or any unknown type) over RPC must fail and append nothing.
	for _, commandType := range []string{"thread.item.upsert", "thread.not-a-command"} {
		command := orchestration.Command{Type: commandType, CommandID: orchestration.CommandID("cmd-reject-" + commandType), ThreadID: threadID}
		if _, err := client.dispatchErr(command); err == nil {
			t.Fatalf("%s dispatched over RPC without error", command.Type)
		}
	}
	if recorded := events.matching(""); len(recorded) != 1 {
		t.Fatalf("events = %#v, want only client-created thread event", recorded)
	}
}

func TestRPCProviderStartAndList(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	client := newRecordingClient(t, s)

	var started provider.InstanceInfo
	client.call(t, wire.MethodProviderStart, map[string]any{
		"instanceId": "codex",
		"name":       "codex",
		"driver":     "acp",
		"config":     map[string]any{"command": helperCommand("sessions")},
	}, &started)
	if started.InstanceID != "codex" || started.Driver != "acp" {
		t.Fatalf("started = %#v, want codex/acp", started)
	}
	if raw, err := json.Marshal(started); err != nil || strings.Contains(string(raw), `"command"`) || strings.Contains(string(raw), `"config"`) {
		t.Fatalf("provider info exposes construction config: %s (marshal err: %v)", raw, err)
	}

	var list []provider.InstanceInfo
	client.call(t, wire.MethodProviderList, nil, &list)
	if len(list) != 3 {
		t.Fatalf("provider.list = %#v, want started ACP plus configured Codex app-server and Claude Code instances", list)
	}
	listed := make(map[provider.InstanceID]provider.InstanceInfo, len(list))
	for _, instance := range list {
		listed[instance.InstanceID] = instance
	}
	if listed["codex"].Status != provider.InstanceStatusInitialized || listed["codex-app-server"].Driver != "codex-app-server" || listed["codex-app-server"].Status != provider.InstanceStatusConfigured {
		t.Fatalf("provider.list = %#v, want initialized ACP and configured Codex app-server instances", list)
	}
	if listed["claude-code"].Driver != "claude-code" || listed["claude-code"].Status != provider.InstanceStatusConfigured {
		t.Fatalf("provider.list = %#v, want a configured Claude Code instance", list)
	}
}

func TestRPCProviderAuthenticateAndLogout(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	client := newRecordingClient(t, s)

	var started provider.InstanceInfo
	client.call(t, wire.MethodProviderStart, wire.ProviderStartParams{InstanceSpec: acpInstanceSpec("codex", "codex", helperCommand("rich-sessions"))}, &started)
	if started.Auth.Status != provider.AuthStatusUnknown || len(started.Auth.Methods) != 1 || started.Auth.Methods[0].ID != "agent-login" {
		t.Fatalf("auth state = %#v, want unknown status with the advertised agent-login method", started.Auth)
	}

	var rejected provider.AuthenticationResult
	if err := client.callErr(wire.MethodProviderAuthenticate, wire.ProviderAuthenticateParams{InstanceID: "codex", MethodID: "not-advertised"}, &rejected); err == nil {
		t.Fatal("authenticate with unadvertised method err = nil, want error")
	}

	var authenticated provider.AuthenticationResult
	client.call(t, wire.MethodProviderAuthenticate, wire.ProviderAuthenticateParams{InstanceID: "codex", MethodID: "agent-login"}, &authenticated)
	if authenticated.Instance.Auth.Status != provider.AuthStatusAuthenticated {
		t.Fatalf("auth status after authenticate = %q, want authenticated", authenticated.Instance.Auth.Status)
	}

	var loggedOut provider.InstanceInfo
	client.call(t, wire.MethodProviderLogout, wire.ProviderInstanceParams{InstanceID: "codex"}, &loggedOut)
	if loggedOut.Auth.Status != provider.AuthStatusUnauthenticated {
		t.Fatalf("auth status after logout = %q, want unauthenticated", loggedOut.Auth.Status)
	}
}

func TestRPCImportProviderSessionDeduplicatesAndReplays(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("codex", "codex", helperCommand("sessions")), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}
	client := newRecordingClient(t, s)
	importCwd := t.TempDir()
	summary := provider.SessionSummary{SessionID: "external-session", Title: "Imported session", Cwd: importCwd, UpdatedAt: "2026-07-15T12:00:00Z"}
	invalid := summary
	invalid.Cwd = "relative/project"
	var rejected wire.ProviderImportSessionResult
	if err := client.callErr(wire.MethodProviderImportSession, wire.ProviderImportSessionParams{InstanceID: "codex", Session: invalid}, &rejected); err == nil {
		t.Fatal("provider.importSession with relative cwd err = nil")
	}

	var first wire.ProviderImportSessionResult
	client.call(t, wire.MethodProviderImportSession, wire.ProviderImportSessionParams{InstanceID: "codex", Session: summary}, &first)
	if first.ThreadID == "" || !first.Imported {
		t.Fatalf("first import = %+v, want a newly imported thread", first)
	}
	var duplicate wire.ProviderImportSessionResult
	client.call(t, wire.MethodProviderImportSession, wire.ProviderImportSessionParams{InstanceID: "codex", Session: summary}, &duplicate)
	if duplicate.ThreadID != first.ThreadID || duplicate.Imported {
		t.Fatalf("duplicate import = %+v, want existing thread %q", duplicate, first.ThreadID)
	}

	var subscribed orchestration.ThreadStreamItem
	client.call(t, wire.MethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: first.ThreadID}, &subscribed)
	if subscribed.Snapshot == nil || subscribed.Snapshot.Thread.Title != summary.Title || subscribed.Snapshot.Thread.Cwd != importCwd || subscribed.Snapshot.Thread.ProviderInstanceID != "codex" {
		t.Fatalf("imported snapshot = %+v", subscribed.Snapshot)
	}
	client.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadSessionPrepare, CommandID: "prepare-imported", ThreadID: first.ThreadID})
	refreshed := client.waitForThreadSnapshot(t, func(snapshot orchestration.ThreadDetailSnapshot) bool {
		return snapshot.Thread.ID == first.ThreadID && !snapshot.HistoryRestorePending
	})
	encoded, err := json.Marshal(refreshed.Snapshot.Thread.Timeline)
	if err != nil {
		t.Fatalf("encode replayed timeline: %v", err)
	}
	if !strings.Contains(string(encoded), "replayed") {
		t.Fatalf("imported timeline = %s, want provider replay", encoded)
	}
	if refreshed.Snapshot.Thread.Session == nil || refreshed.Snapshot.Thread.Session.ProviderInstanceID != "codex" || refreshed.Snapshot.Thread.Session.Cwd != importCwd {
		t.Fatalf("prepared imported session = %+v, want codex binding in %q", refreshed.Snapshot.Thread.Session, importCwd)
	}
}

func TestRPCImportProviderSessionRejectsProviderWithoutRestore(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("list-only", "list-only", helperCommand("list-only-sessions")), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}
	client := newRecordingClient(t, s)
	var result wire.ProviderImportSessionResult
	err := client.callErr(wire.MethodProviderImportSession, wire.ProviderImportSessionParams{
		InstanceID: "list-only",
		Session: provider.SessionSummary{
			SessionID: "external-session",
			Cwd:       t.TempDir(),
		},
	}, &result)
	if err == nil || !strings.Contains(err.Error(), "does not support restoring imported sessions") {
		t.Fatalf("provider.importSession err = %v, want restore capability error", err)
	}
}

func TestRPCProviderSessionManagement(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("codex", "codex", helperCommand("sessions")), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}
	client := newRecordingClient(t, s)
	threadID := orchestration.ThreadID("thread-session-mgmt")
	cwd := t.TempDir()

	client.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-create-mgmt", ThreadID: threadID, Title: "Session mgmt", ProviderInstanceID: "codex", Cwd: cwd})
	var snapshot orchestration.ThreadStreamItem
	client.call(t, wire.MethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: threadID}, &snapshot)
	client.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-turn-mgmt", ThreadID: threadID, Message: &orchestration.CommandMessage{MessageID: "msg-mgmt", Text: "hello"}})
	client.waitForThreadEvent(t, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadMessageSent && event.Payload.Role == orchestration.MessageRoleAssistant
	})

	var sessions []provider.SessionSummary
	client.call(t, wire.MethodProviderListSessions, wire.ProviderListSessionsParams{InstanceID: "codex"}, &sessions)
	if len(sessions) != 1 || sessions[0].SessionID != "sess_new" || sessions[0].Cwd != cwd || sessions[0].Title != "Test session" {
		t.Fatalf("provider.listSessions = %#v, want the agent session created for the thread", sessions)
	}

	var ignored json.RawMessage
	err := client.callErr(wire.MethodProviderDeleteSession, wire.ProviderSessionParams{InstanceID: "codex", SessionID: "unbound-session"}, &ignored)
	if err == nil || !strings.Contains(err.Error(), "session delete") {
		t.Fatalf("provider.deleteSession err = %v, want capability-gated session-delete error", err)
	}

	err = client.callErr(wire.MethodProviderCloseSession, wire.ProviderSessionParams{InstanceID: "codex", SessionID: "sess_new"}, &ignored)
	if err == nil || !strings.Contains(err.Error(), "bound to thread") {
		t.Fatalf("provider.closeSession bound session err = %v, want rejection", err)
	}
	client.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadSessionStop, CommandID: "cmd-stop-mgmt", ThreadID: threadID})
	client.waitForThreadEvent(t, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadSessionStatusSet && event.Payload.Session != nil && event.Payload.Session.Status == orchestration.SessionStatusStopped
	})
	client.call(t, wire.MethodProviderCloseSession, wire.ProviderSessionParams{InstanceID: "codex", SessionID: "sess_new"}, &ignored)
}

// TestRPCSessionMetadataProjectionsReachClient locks in the projections real
// agents emit during a prompt: slash commands, an agent-set title, token usage,
// and session config options. Config-option switching round-trips, and a late
// subscriber receives the fully projected state.
func TestRPCSessionMetadataProjectionsReachClient(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("codex", "codex", helperCommand("rich-sessions")), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}
	client := newRecordingClient(t, s)
	threadID := orchestration.ThreadID("thread-metadata")

	client.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-create-metadata", ThreadID: threadID, Title: "Metadata thread", ProviderInstanceID: "codex", Cwd: t.TempDir()})
	var snapshot orchestration.ThreadStreamItem
	client.call(t, wire.MethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: threadID}, &snapshot)
	client.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-turn-metadata", ThreadID: threadID, Message: &orchestration.CommandMessage{MessageID: "msg-metadata", Text: "hello"}})

	// Session materialization publishes the agent's config options first.
	configEvent := client.waitForThreadEvent(t, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadConfigOptionsUpdated
	})
	if value, ok := configOptionValue(configEvent.Payload.ConfigOptions, "mode"); !ok || value != "ask" {
		t.Fatalf("initial config options = %#v, want mode option with currentValue ask", configEvent.Payload.ConfigOptions)
	}
	if value, ok := configOptionValue(configEvent.Payload.ConfigOptions, "model"); !ok || value != "test-model-1" {
		t.Fatalf("initial config options = %#v, want model option with currentValue test-model-1", configEvent.Payload.ConfigOptions)
	}

	slashEvent := client.waitForThreadEvent(t, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadSlashCommandsUpdated
	})
	if len(slashEvent.Payload.SlashCommands) != 1 || slashEvent.Payload.SlashCommands[0].Name != "compact" {
		t.Fatalf("slash commands = %#v, want the agent's compact command", slashEvent.Payload.SlashCommands)
	}

	client.waitForThreadEvent(t, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadMetaUpdated && event.Payload.Title == "Agent set title"
	})

	usageEvent := client.waitForThreadEvent(t, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadTokenUsageUpdated
	})
	usage := usageEvent.Payload.TokenUsage
	if usage == nil || usage.UsedTokens != 1200 || usage.MaxTokens != 200000 || usage.Cost != 0.42 || usage.Currency != "USD" {
		t.Fatalf("token usage = %#v, want used 1200 / max 200000 / cost 0.42 USD", usage)
	}

	client.waitForThreadEvent(t, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadMessageSent && event.Payload.Role == orchestration.MessageRoleAssistant
	})

	// Model switching round-trips through session/set_config_option. Keeping the
	// category-specific case also verifies the thread's model projection.
	client.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadConfigOptionSet, CommandID: "cmd-model-metadata", ThreadID: threadID, OptionID: "model", Value: "test-model-2"})
	client.waitForThreadEvent(t, func(event orchestration.Event) bool {
		if event.Type != orchestration.EventThreadConfigOptionsUpdated {
			return false
		}
		value, ok := configOptionValue(event.Payload.ConfigOptions, "model")
		return ok && value == "test-model-2"
	})

	lateClient := newRecordingClient(t, s)
	var late orchestration.ThreadStreamItem
	lateClient.call(t, wire.MethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: threadID}, &late)
	if late.Kind != "snapshot" || late.Snapshot == nil {
		t.Fatalf("late subscription = %#v, want snapshot", late)
	}
	thread := late.Snapshot.Thread
	if thread.Title != "Agent set title" {
		t.Fatalf("thread title = %q, want agent-set title", thread.Title)
	}
	if thread.Session == nil {
		t.Fatal("thread session missing after turn")
	}
	if len(thread.Session.SlashCommands) != 1 || thread.Session.SlashCommands[0].Name != "compact" {
		t.Fatalf("session slash commands = %#v, want compact", thread.Session.SlashCommands)
	}
	if thread.Session.TokenUsage == nil || thread.Session.TokenUsage.UsedTokens != 1200 {
		t.Fatalf("session token usage = %#v, want used 1200", thread.Session.TokenUsage)
	}
	if value, ok := configOptionValue(thread.Session.ConfigOptions, "mode"); !ok || value != "ask" {
		t.Fatalf("session config options = %#v, want unchanged mode ask", thread.Session.ConfigOptions)
	}
	if value, ok := configOptionValue(thread.Session.ConfigOptions, "model"); !ok || value != "test-model-2" {
		t.Fatalf("session config options = %#v, want model test-model-2", thread.Session.ConfigOptions)
	}
	if thread.ModelSelection == nil || thread.ModelSelection.Model != "test-model-2" {
		t.Fatalf("thread model selection = %#v, want test-model-2", thread.ModelSelection)
	}
}

func configOptionValue(options []provider.ConfigOption, optionID string) (string, bool) {
	for _, option := range options {
		if option.ID == optionID {
			value, ok := option.CurrentValue.(string)
			return value, ok
		}
	}
	return "", false
}

func TestRPCErrorPreservesAgentRequestError(t *testing.T) {
	err := rpcError(&provider.RequestError{Code: -32000, Message: "Authentication required", Data: json.RawMessage(`{"method":"login"}`)})
	wireErr, ok := err.(*jsonrpc2.WireError)
	if !ok {
		t.Fatalf("rpcError = %T, want WireError", err)
	}
	if wireErr.Code != -32000 || wireErr.Message != "Authentication required" || string(wireErr.Data) != `{"method":"login"}` {
		t.Fatalf("wire error = %#v", wireErr)
	}
}

func TestRPCHistoryReplayPublishesOneAuthoritativeRefresh(t *testing.T) {
	s := newTestServer(t)
	t.Cleanup(func() { _ = s.Close() })

	threadID := orchestration.ThreadID("thread-replay-refresh")
	s.orchestration.RestoreThreads([]orchestration.RestoredThread{{
		ThreadID: threadID,
		Title:    "Replay refresh",
	}})
	client := registerTestRPCClient(t, s, "client-replay-refresh")
	client.subscribeThread(threadID)
	appendEvent := func(input orchestration.EventInput) {
		t.Helper()
		input.ThreadID = threadID
		if _, err := s.orchestration.AppendEvent(context.Background(), input); err != nil {
			t.Fatalf("append %s: %v", input.Type, err)
		}
	}
	appendChunks := func(from, to int) {
		t.Helper()
		for index := from; index < to; index++ {
			appendEvent(orchestration.EventInput{Type: orchestration.EventThreadMessageSent, Payload: orchestration.EventPayload{
				MessageID: "message-replay", Role: orchestration.MessageRoleAssistant, Text: fmt.Sprintf("chunk-%02d ", index),
			}})
		}
	}

	// The real prepare event is what opens the replay publication window. Call
	// the publisher directly here so the provider reactor cannot race this
	// focused transport test.
	s.publishOrchestrationEvent(orchestration.Event{
		Type:    orchestration.EventThreadSessionPrepareRequested,
		Payload: orchestration.EventPayload{ThreadID: threadID},
	})
	appendChunks(0, 16)
	// A runtime error can be part of successfully loaded history. It must be
	// included in the final snapshot without ending transport coalescing.
	appendEvent(orchestration.EventInput{Type: orchestration.EventThreadSessionStatusSet, Payload: orchestration.EventPayload{
		Session: &orchestration.SessionBinding{Status: orchestration.SessionStatusError, LastError: "historical runtime error"},
	}})
	if got := len(client.outbound); got != 0 {
		t.Fatalf("outbound replay updates = %d, want 0", got)
	}
	appendChunks(16, 32)
	appendEvent(orchestration.EventInput{Type: orchestration.EventThreadHistoryReplayCompleted})
	if client.closed.Load() {
		t.Fatal("client closed while publishing collapsed replay")
	}
	if got := len(client.outbound); got != 1 {
		t.Fatalf("outbound terminal updates = %d, want one snapshot", got)
	}

	msg := <-client.outbound
	raw, ok := msg.params.(json.RawMessage)
	if !ok {
		t.Fatalf("snapshot params = %T, want json.RawMessage", msg.params)
	}
	var refresh orchestration.ThreadStreamItem
	if err := json.Unmarshal(raw, &refresh); err != nil {
		t.Fatal(err)
	}
	if refresh.Kind != orchestration.StreamItemSnapshot || refresh.Snapshot == nil {
		t.Fatalf("refresh = %#v, want snapshot", refresh)
	}
	encoded, err := json.Marshal(refresh.Snapshot.Thread.Timeline)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), "chunk-31") {
		t.Fatalf("refresh timeline = %s, want final replay content", encoded)
	}
}

func TestRPCSubscribeThreadSnapshotHasNoLiveGap(t *testing.T) {
	s := newTestServer(t)
	t.Cleanup(func() { _ = s.Close() })
	threadID := orchestration.ThreadID("thread-snapshot-race")
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "snapshot-race-create", ThreadID: threadID, Title: "before-boundary"}); err != nil {
		t.Fatal(err)
	}

	client := registerTestRPCClient(t, s, "client-snapshot-race")
	handler := &rpcHandler{server: s, client: client, afterThreadSnapshot: func(orchestration.ThreadID) {
		if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadMetaUpdate, CommandID: "snapshot-race-after", ThreadID: threadID, Title: "after-boundary"}); err != nil {
			t.Fatal(err)
		}
	}}
	result, err := handleThreadCall(handler, wire.MethodOrchestrationSubscribeThread, threadID)
	if err != nil {
		t.Fatal(err)
	}
	item := result.(orchestration.ThreadStreamItem)
	if item.Snapshot == nil || item.Snapshot.Thread.Title != "before-boundary" {
		t.Fatalf("snapshot response = %#v", item)
	}

	select {
	case msg := <-client.outbound:
		raw, ok := msg.params.(json.RawMessage)
		if msg.method != wire.MethodOrchestrationSubscribeThread || !ok {
			t.Fatalf("notification = %#v, want pre-marshaled subscribeThread event", msg)
		}
		var live orchestration.ThreadStreamItem
		if err := json.Unmarshal(raw, &live); err != nil {
			t.Fatal(err)
		}
		if live.Event == nil || live.Event.Payload.Title != "after-boundary" || live.Event.Sequence <= item.Snapshot.SnapshotSequence {
			t.Fatalf("live boundary event = %#v, snapshot sequence %d", live, item.Snapshot.SnapshotSequence)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for live boundary event")
	}
}
