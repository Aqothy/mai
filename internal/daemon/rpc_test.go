package daemon

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Aqothy/jsonrpc2"
	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/providerservice"
	"github.com/coder/websocket"
)

type rpcTestClientHandler struct {
	threadItems chan orchestration.ThreadStreamItem
}

func (h rpcTestClientHandler) Handle(ctx context.Context, req *jsonrpc2.Request) (any, error) {
	switch req.Method {
	case RPCMethodOrchestrationSubscribeThread:
		var item orchestration.ThreadStreamItem
		if err := decodeRPCParams(req, &item); err != nil {
			return nil, err
		}
		if h.threadItems != nil {
			select {
			case h.threadItems <- item:
			default:
			}
		}
		return nil, nil
	default:
		if req.IsCall() {
			return nil, jsonrpc2.ErrNotHandled
		}
		return nil, nil
	}
}

func newRPCTestClient(t testing.TB, s *Server, handler jsonrpc2.Handler) *jsonrpc2.Connection {
	t.Helper()
	server := httptest.NewServer(s.WebSocketHandler())
	t.Cleanup(server.Close)
	url := "ws" + strings.TrimPrefix(server.URL, "http")
	ws, _, err := websocket.Dial(context.Background(), url, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	conn := jsonrpc2.NewWebSocketConnection(context.Background(), wsJSONRPC{conn: ws}, handler)
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

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

func TestWebClientHandlerServesEmbeddedIndex(t *testing.T) {
	recorder := httptest.NewRecorder()
	webClientHandler().ServeHTTP(recorder, httptest.NewRequest("GET", "/", nil))

	if recorder.Code != 200 {
		t.Fatalf("GET / status = %d, want 200", recorder.Code)
	}
	if body := recorder.Body.String(); !strings.Contains(body, "<title>maiD</title>") || !strings.Contains(body, `<div id="root"></div>`) {
		t.Fatalf("GET / body = %q, want embedded maiD index", body)
	}
}

func TestRPCSubscribeThreadDoesNotRegisterMissingThread(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	threadID := orchestration.ThreadID("missing-thread")
	client := &rpcClient{threadSubscriptions: make(map[orchestration.ThreadID]struct{})}
	handler := &rpcHandler{server: s, client: client}
	req, err := jsonrpc2.NewCall(jsonrpc2.StringID("1"), RPCMethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: threadID})
	if err != nil {
		t.Fatalf("new call: %v", err)
	}

	if _, err := handler.Handle(context.Background(), req); err == nil {
		t.Fatal("subscribeThread missing thread err = nil, want error")
	}
	if client.subscribedThread(threadID) {
		t.Fatalf("client remained subscribed to %q after failed snapshot", threadID)
	}
}

func TestRPCGetItemDetailReturnsCanonicalToolData(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()

	threadID := orchestration.ThreadID("thread-item-detail")
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{
		Type:      orchestration.CommandThreadCreate,
		CommandID: "create-item-detail",
		ThreadID:  threadID,
		Title:     "Item detail",
	}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := s.orchestration.AppendEvent(context.Background(), orchestration.EventInput{
		Type:     orchestration.EventThreadItemUpserted,
		ThreadID: threadID,
		Payload: orchestration.EventPayload{Item: &orchestration.Item{
			ID:     "tool-1",
			Kind:   provider.ItemKindCommandExecution,
			Status: provider.ItemStatusCompleted,
			ToolCall: &provider.ToolCall{
				Action:  provider.ToolActionExecute,
				Command: "go test ./...",
				Output:  "ok",
			},
		}},
	}); err != nil {
		t.Fatalf("append tool event: %v", err)
	}

	handler := &rpcHandler{
		server: s,
		client: &rpcClient{threadSubscriptions: make(map[orchestration.ThreadID]struct{})},
	}
	req, err := jsonrpc2.NewCall(
		jsonrpc2.StringID("1"),
		RPCMethodOrchestrationGetItemDetail,
		orchestration.GetItemDetailInput{ThreadID: threadID, ItemID: "tool-1"},
	)
	if err != nil {
		t.Fatalf("new getItemDetail call: %v", err)
	}
	result, err := handler.Handle(context.Background(), req)
	if err != nil {
		t.Fatalf("getItemDetail: %v", err)
	}
	item, ok := result.(orchestration.Item)
	if !ok || item.ToolCall == nil || item.ToolCall.Output != "ok" {
		t.Fatalf("getItemDetail result = %#v", result)
	}
	if item.ToolCallSummary != nil || item.DetailAvailable {
		t.Fatalf("getItemDetail returned compact projection: %#v", item)
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
	first, err := handler.getProviderOptions(context.Background(), providerOptionsGetParams{
		ProviderInstanceID: "provider-a", Cwd: "/first",
	})
	if err != nil {
		t.Fatalf("first get: %v", err)
	}
	_, err = handler.getProviderOptions(context.Background(), providerOptionsGetParams{
		ProviderInstanceID: "provider-b", Cwd: "/other",
	})
	if err != nil {
		t.Fatalf("second provider get: %v", err)
	}
	reused, err := handler.getProviderOptions(context.Background(), providerOptionsGetParams{
		ProviderInstanceID: "provider-a", Cwd: "/first",
	})
	if err != nil {
		t.Fatalf("reused get: %v", err)
	}
	if reused.OptionsSessionID != first.OptionsSessionID ||
		instances["provider-a"].openCount() != 1 ||
		instances["provider-b"].openCount() != 1 {
		t.Fatalf("warm switch-back opened another session: first=%#v reused=%#v", first, reused)
	}
	instances["provider-a"].publishOptions("handle-/first", []provider.ConfigOption{{
		ID: "model", Type: provider.ConfigOptionTypeSelect, CurrentValue: "slow",
	}})
	select {
	case message := <-client.outbound:
		update, ok := message.params.(providerOptionsResult)
		if message.method != wire.MethodProviderOptionsUpdated ||
			!ok ||
			update.OptionsSessionID != first.OptionsSessionID ||
			len(update.ConfigOptions) != 1 ||
			update.ConfigOptions[0].CurrentValue != "slow" {
			t.Fatalf("options update notification = %#v", message)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("spontaneous options update was not routed to the client")
	}

	closeStarted := make(chan struct{}, 1)
	closeBlock := make(chan struct{})
	instances["provider-a"].mu.Lock()
	instances["provider-a"].closeStarted = closeStarted
	instances["provider-a"].closeBlock = closeBlock
	instances["provider-a"].mu.Unlock()
	type replacementResult struct {
		result providerOptionsResult
		err    error
	}
	replacementDone := make(chan replacementResult, 1)
	go func() {
		result, err := handler.getProviderOptions(context.Background(), providerOptionsGetParams{
			ProviderInstanceID: "provider-a", Cwd: "/second",
		})
		replacementDone <- replacementResult{result: result, err: err}
	}()
	select {
	case <-closeStarted:
	case <-time.After(2 * time.Second):
		close(closeBlock)
		t.Fatal("replacement did not begin closing the old options session")
	}
	var replacement providerOptionsResult
	select {
	case result := <-replacementDone:
		if result.err != nil {
			close(closeBlock)
			t.Fatalf("replacement get: %v", result.err)
		}
		if result.result.OptionsSessionID == first.OptionsSessionID {
			close(closeBlock)
			t.Fatal("cwd replacement reused the old options ID")
		}
		replacement = result.result
	case <-time.After(2 * time.Second):
		close(closeBlock)
		t.Fatal("replacement waited for best-effort close of the old options session")
	}
	close(closeBlock)
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
	if _, err := handler.setProviderOption(context.Background(), providerOptionsSetParams{
		OptionsSessionID: replacement.OptionsSessionID, OptionID: "model", Value: "slow",
	}); err == nil {
		t.Fatal("set with invalidated optionsSessionId succeeded")
	}
	reopenedAfterInvalidation, err := handler.getProviderOptions(context.Background(), providerOptionsGetParams{
		ProviderInstanceID: "provider-a", Cwd: "/second",
	})
	if err != nil || reopenedAfterInvalidation.OptionsSessionID == replacement.OptionsSessionID {
		t.Fatalf("reopen invalidated provider-a session = %#v, err = %v", reopenedAfterInvalidation, err)
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
}

func (p *optionsRPCProvider) Info() provider.InstanceInfo { return p.info }
func (p *optionsRPCProvider) Close() error                { return nil }
func (p *optionsRPCProvider) StartSession(context.Context, provider.StartSessionInput) (provider.StartSessionResult, error) {
	return provider.StartSessionResult{}, nil
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
	return provider.OptionsSession{Handle: handle, ConfigOptions: options}, nil
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
func TestRPCClientKeepsIndependentThreadSubscriptions(t *testing.T) {
	client := &rpcClient{threadSubscriptions: make(map[orchestration.ThreadID]struct{})}
	threadA := orchestration.ThreadID("thread-a")
	threadB := orchestration.ThreadID("thread-b")

	client.subscribeThread(threadA)
	client.subscribeThread(threadB)
	client.unsubscribeThread(threadA)

	if client.subscribedThread(threadA) {
		t.Fatal("thread A remained subscribed after its explicit unsubscribe")
	}
	if !client.subscribedThread(threadB) {
		t.Fatal("unsubscribing thread A removed the independent thread B subscription")
	}
}

func TestRPCUnsubscribeThreadStopsNotifications(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	threadID := orchestration.ThreadID("thread-unsubscribe")
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "create-unsubscribe", ThreadID: threadID, Title: "before"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}

	client := &rpcClient{id: "client-unsubscribe", outbound: make(chan rpcOutbound, 8), done: make(chan struct{}), threadSubscriptions: make(map[orchestration.ThreadID]struct{})}
	s.rpcMu.Lock()
	s.rpcClients[client.id] = client
	s.rpcMu.Unlock()
	defer func() {
		s.rpcMu.Lock()
		delete(s.rpcClients, client.id)
		s.rpcMu.Unlock()
		client.closeOutbound()
	}()

	handler := &rpcHandler{server: s, client: client}
	subscribe, err := jsonrpc2.NewCall(jsonrpc2.StringID("1"), RPCMethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: threadID})
	if err != nil {
		t.Fatalf("new subscribe call: %v", err)
	}
	if _, err := handler.Handle(context.Background(), subscribe); err != nil {
		t.Fatalf("subscribeThread: %v", err)
	}
	// Engine listeners (including client fan-out) run before Dispatch returns,
	// so outbound state is settled after each dispatch below.
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadMetaUpdate, CommandID: "meta-while-subscribed", ThreadID: threadID, Title: "while-subscribed"}); err != nil {
		t.Fatalf("thread.meta.update: %v", err)
	}
	select {
	case msg := <-client.outbound:
		if msg.method != RPCMethodOrchestrationSubscribeThread {
			t.Fatalf("notification method = %q, want subscribeThread", msg.method)
		}
	default:
		t.Fatal("expected a live event while subscribed")
	}

	unsubscribe, err := jsonrpc2.NewCall(jsonrpc2.StringID("2"), RPCMethodOrchestrationUnsubscribeThread, orchestration.SubscribeThreadInput{ThreadID: threadID})
	if err != nil {
		t.Fatalf("new unsubscribe call: %v", err)
	}
	if _, err := handler.Handle(context.Background(), unsubscribe); err != nil {
		t.Fatalf("unsubscribeThread: %v", err)
	}
	if client.subscribedThread(threadID) {
		t.Fatal("client still subscribed after unsubscribeThread")
	}
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadMetaUpdate, CommandID: "meta-after-unsubscribe", ThreadID: threadID, Title: "after-unsubscribe"}); err != nil {
		t.Fatalf("thread.meta.update after unsubscribe: %v", err)
	}
	select {
	case msg := <-client.outbound:
		t.Fatalf("unexpected notification after unsubscribe: %#v", msg)
	default:
	}
}

// TestRPCOrchestrationApprovalRespondHonorsExplicitOption sends an accept
// decision together with an explicit optionId for a reject option. The helper
// agent (deny mode) fails unless it receives exactly "reject", proving the
// selected option — not the kind-mapped decision — reaches the agent.
func TestRPCOrchestrationApprovalRespondHonorsExplicitOption(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("codex", "codex", helperCommand("permission-deny-sessions")), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}

	threadItems := make(chan orchestration.ThreadStreamItem, 16)
	client := newRPCTestClient(t, s, rpcTestClientHandler{threadItems: threadItems})
	ctx := context.Background()
	threadID := orchestration.ThreadID("thread-permission-option")

	var receipt orchestration.DispatchResult
	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-create-perm-option", ThreadID: threadID, Title: "Permission option thread", ProviderInstanceID: "codex", Cwd: t.TempDir()}).Await(ctx, &receipt); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	var snapshot orchestration.ThreadStreamItem
	if err := client.Call(ctx, RPCMethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: threadID}).Await(ctx, &snapshot); err != nil {
		t.Fatalf("subscribeThread: %v", err)
	}
	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-turn-perm-option", ThreadID: threadID, Message: &orchestration.CommandMessage{MessageID: "msg-perm-option", Text: "hello"}}).Await(ctx, &receipt); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}

	approvalEvent := waitForThreadEvent(t, threadItems, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadApprovalOpened && event.Payload.Approval != nil
	})
	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadApprovalRespond, CommandID: "cmd-approval-option", ThreadID: threadID, RequestID: orchestration.ApprovalID(approvalEvent.Payload.Approval.RequestID), Decision: provider.ApprovalDecisionAccept, OptionID: "reject"}).Await(ctx, &receipt); err != nil {
		t.Fatalf("thread.approval.respond: %v", err)
	}

	resolved := waitForThreadEvent(t, threadItems, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadApprovalResolved && event.Payload.Approval != nil
	})
	// The resolved decision derives from the option the agent actually
	// received, so the accept decision must come back as decline.
	if resolved.Payload.Approval.OptionID != "reject" || resolved.Payload.Approval.Decision != provider.ApprovalDecisionDecline {
		t.Fatalf("resolved = %#v, want the explicitly selected reject option", resolved.Payload.Approval)
	}
}

func TestRPCFailedDispatchReturnsNilResult(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	client := &rpcClient{threadSubscriptions: make(map[orchestration.ThreadID]struct{})}
	handler := &rpcHandler{server: s, client: client}
	req, err := jsonrpc2.NewCall(jsonrpc2.StringID("1"), RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadTurnInterrupt, CommandID: "cmd-bad-interrupt", ThreadID: "missing-thread"})
	if err != nil {
		t.Fatalf("new call: %v", err)
	}

	result, err := handler.Handle(context.Background(), req)
	if err == nil {
		t.Fatal("interrupt on missing thread err = nil, want error")
	}
	if result != nil {
		t.Fatalf("failed dispatch result = %#v, want nil (non-nil result with non-nil error violates the jsonrpc2 handler contract)", result)
	}
}

func TestRPCOrchestrationDispatchRejectsInternalCommands(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	events := observeServerEvents(t, s)
	client := newRPCTestClient(t, s, rpcTestClientHandler{})
	ctx := context.Background()

	threadID := orchestration.ThreadID("thread-reject-internal")
	var receipt orchestration.DispatchResult
	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-create-reject-internal", ThreadID: threadID, Title: "Reject internal", ProviderInstanceID: "codex"}).Await(ctx, &receipt); err != nil {
		t.Fatalf("thread.create: %v", err)
	}

	// Provider/server event types are not commands: dispatching their former
	// command names (or any unknown type) over RPC must fail and append nothing.
	internalTypes := []string{
		"thread.session.status.set",
		"thread.message.user.delta",
		"thread.message.assistant.delta",
		"thread.message.assistant.complete",
		"thread.item.upsert",
		"thread.plan.update",
		"thread.approval.open",
		"thread.approval.resolve",
		"thread.config-options.update",
		"thread.slash-commands.update",
		"thread.token-usage.update",
		"thread.title.update",
		"thread.interaction-mode.confirm",
	}
	internalCommands := make([]orchestration.Command, 0, len(internalTypes))
	for _, commandType := range internalTypes {
		internalCommands = append(internalCommands, orchestration.Command{Type: commandType, CommandID: orchestration.CommandID("cmd-reject-" + commandType), ThreadID: threadID})
	}
	for _, command := range internalCommands {
		if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, command).Await(ctx, &receipt); err == nil {
			t.Fatalf("%s dispatched over RPC without error", command.Type)
		}
	}
	if recorded := events.matching("", 0); len(recorded) != 1 {
		t.Fatalf("events = %#v, want only client-created thread event", recorded)
	}
}

func TestRPCProviderStartAndList(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	client := newRPCTestClient(t, s, rpcTestClientHandler{})
	ctx := context.Background()

	var started provider.InstanceInfo
	if err := client.Call(ctx, RPCMethodProviderStart, map[string]any{
		"instanceId": "codex",
		"name":       "codex",
		"driver":     "acp",
		"config":     map[string]any{"command": helperCommand("sessions")},
	}).Await(ctx, &started); err != nil {
		t.Fatalf("provider.start: %v", err)
	}
	if started.InstanceID != "codex" || started.Driver != "acp" {
		t.Fatalf("started = %#v, want codex/acp", started)
	}
	if raw, err := json.Marshal(started); err != nil || strings.Contains(string(raw), `"command"`) || strings.Contains(string(raw), `"config"`) {
		t.Fatalf("provider info exposes construction config: %s (marshal err: %v)", raw, err)
	}

	var list []provider.InstanceInfo
	if err := client.Call(ctx, RPCMethodProviderList, nil).Await(ctx, &list); err != nil {
		t.Fatalf("provider.list: %v", err)
	}
	if len(list) != 1 || list[0].InstanceID != "codex" {
		t.Fatalf("provider.list = %#v, want one codex instance", list)
	}
}

func TestRPCProviderAuthenticateAndLogout(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	client := newRPCTestClient(t, s, rpcTestClientHandler{})
	ctx := context.Background()

	var started provider.InstanceInfo
	if err := client.Call(ctx, RPCMethodProviderStart, providerStartRPCParams{InstanceSpec: acpInstanceSpec("codex", "codex", helperCommand("rich-sessions"))}).Await(ctx, &started); err != nil {
		t.Fatalf("provider.start: %v", err)
	}
	if started.Auth.Status != provider.AuthStatusUnknown || len(started.Auth.Methods) != 1 || started.Auth.Methods[0].ID != "agent-login" {
		t.Fatalf("auth state = %#v, want unknown status with the advertised agent-login method", started.Auth)
	}

	var rejected provider.InstanceInfo
	if err := client.Call(ctx, RPCMethodProviderAuthenticate, providerAuthenticateParams{InstanceID: "codex", MethodID: "not-advertised"}).Await(ctx, &rejected); err == nil {
		t.Fatal("authenticate with unadvertised method err = nil, want error")
	}

	var authenticated provider.InstanceInfo
	if err := client.Call(ctx, RPCMethodProviderAuthenticate, providerAuthenticateParams{InstanceID: "codex", MethodID: "agent-login"}).Await(ctx, &authenticated); err != nil {
		t.Fatalf("provider.authenticate: %v", err)
	}
	if authenticated.Auth.Status != provider.AuthStatusAuthenticated {
		t.Fatalf("auth status after authenticate = %q, want authenticated", authenticated.Auth.Status)
	}

	var loggedOut provider.InstanceInfo
	if err := client.Call(ctx, RPCMethodProviderLogout, providerInstanceParams{InstanceID: "codex"}).Await(ctx, &loggedOut); err != nil {
		t.Fatalf("provider.logout: %v", err)
	}
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
	threadItems := make(chan orchestration.ThreadStreamItem, 64)
	client := newRPCTestClient(t, s, rpcTestClientHandler{threadItems: threadItems})
	ctx := context.Background()
	importCwd := t.TempDir()
	summary := provider.SessionSummary{SessionID: "external-session", Title: "Imported session", Cwd: importCwd, UpdatedAt: "2026-07-15T12:00:00Z"}
	invalid := summary
	invalid.Cwd = "relative/project"
	var rejected providerImportSessionResult
	if err := client.Call(ctx, RPCMethodProviderImportSession, providerImportSessionParams{InstanceID: "codex", Session: invalid}).Await(ctx, &rejected); err == nil {
		t.Fatal("provider.importSession with relative cwd err = nil")
	}

	var first providerImportSessionResult
	if err := client.Call(ctx, RPCMethodProviderImportSession, providerImportSessionParams{InstanceID: "codex", Session: summary}).Await(ctx, &first); err != nil {
		t.Fatalf("provider.importSession: %v", err)
	}
	if first.ThreadID == "" || !first.Imported {
		t.Fatalf("first import = %+v, want a newly imported thread", first)
	}
	var duplicate providerImportSessionResult
	if err := client.Call(ctx, RPCMethodProviderImportSession, providerImportSessionParams{InstanceID: "codex", Session: summary}).Await(ctx, &duplicate); err != nil {
		t.Fatalf("duplicate provider.importSession: %v", err)
	}
	if duplicate.ThreadID != first.ThreadID || duplicate.Imported {
		t.Fatalf("duplicate import = %+v, want existing thread %q", duplicate, first.ThreadID)
	}

	var subscribed orchestration.ThreadStreamItem
	if err := client.Call(ctx, RPCMethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: first.ThreadID}).Await(ctx, &subscribed); err != nil {
		t.Fatalf("subscribe imported thread: %v", err)
	}
	if subscribed.Snapshot == nil || subscribed.Snapshot.Thread.Title != summary.Title || subscribed.Snapshot.Thread.Cwd != importCwd || subscribed.Snapshot.Thread.ProviderInstanceID != "codex" {
		t.Fatalf("imported snapshot = %+v", subscribed.Snapshot)
	}
	var receipt orchestration.DispatchResult
	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadSessionPrepare, CommandID: "prepare-imported", ThreadID: first.ThreadID}).Await(ctx, &receipt); err != nil {
		t.Fatalf("prepare imported thread: %v", err)
	}
	waitForThreadEvent(t, threadItems, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadHistoryReplayCompleted
	})
	var refreshed orchestration.ThreadStreamItem
	if err := client.Call(ctx, RPCMethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: first.ThreadID}).Await(ctx, &refreshed); err != nil {
		t.Fatalf("resubscribe imported thread: %v", err)
	}
	if refreshed.Snapshot == nil {
		t.Fatalf("resubscribe imported thread = %#v, want snapshot", refreshed)
	}
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
	client := newRPCTestClient(t, s, rpcTestClientHandler{})
	var result providerImportSessionResult
	err := client.Call(context.Background(), RPCMethodProviderImportSession, providerImportSessionParams{
		InstanceID: "list-only",
		Session: provider.SessionSummary{
			SessionID: "external-session",
			Cwd:       t.TempDir(),
		},
	}).Await(context.Background(), &result)
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
	threadItems := make(chan orchestration.ThreadStreamItem, 64)
	client := newRPCTestClient(t, s, rpcTestClientHandler{threadItems: threadItems})
	ctx := context.Background()
	threadID := orchestration.ThreadID("thread-session-mgmt")
	cwd := t.TempDir()

	var receipt orchestration.DispatchResult
	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-create-mgmt", ThreadID: threadID, Title: "Session mgmt", ProviderInstanceID: "codex", Cwd: cwd}).Await(ctx, &receipt); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	var snapshot orchestration.ThreadStreamItem
	if err := client.Call(ctx, RPCMethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: threadID}).Await(ctx, &snapshot); err != nil {
		t.Fatalf("subscribeThread: %v", err)
	}
	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-turn-mgmt", ThreadID: threadID, Message: &orchestration.CommandMessage{MessageID: "msg-mgmt", Text: "hello"}}).Await(ctx, &receipt); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	waitForThreadEvent(t, threadItems, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadMessageSent && event.Payload.Role == orchestration.MessageRoleAssistant
	})

	var sessions []provider.SessionSummary
	if err := client.Call(ctx, RPCMethodProviderListSessions, providerListSessionsParams{InstanceID: "codex"}).Await(ctx, &sessions); err != nil {
		t.Fatalf("provider.listSessions: %v", err)
	}
	if len(sessions) != 1 || sessions[0].SessionID != "sess_new" || sessions[0].Cwd != cwd || sessions[0].Title != "Test session" {
		t.Fatalf("provider.listSessions = %#v, want the agent session created for the thread", sessions)
	}

	var ignored json.RawMessage
	err := client.Call(ctx, RPCMethodProviderDeleteSession, providerSessionParams{InstanceID: "codex", SessionID: "unbound-session"}).Await(ctx, &ignored)
	if err == nil || !strings.Contains(err.Error(), "session/delete") {
		t.Fatalf("provider.deleteSession err = %v, want capability-gated session/delete error", err)
	}

	err = client.Call(ctx, RPCMethodProviderCloseSession, providerSessionParams{InstanceID: "codex", SessionID: "sess_new"}).Await(ctx, &ignored)
	if err == nil || !strings.Contains(err.Error(), "bound to thread") {
		t.Fatalf("provider.closeSession bound session err = %v, want rejection", err)
	}
	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadSessionStop, CommandID: "cmd-stop-mgmt", ThreadID: threadID}).Await(ctx, &receipt); err != nil {
		t.Fatalf("thread.session.stop: %v", err)
	}
	waitForThreadEvent(t, threadItems, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadSessionStatusSet && event.Payload.Session != nil && event.Payload.Session.Status == orchestration.SessionStatusStopped
	})
	if err := client.Call(ctx, RPCMethodProviderCloseSession, providerSessionParams{InstanceID: "codex", SessionID: "sess_new"}).Await(ctx, &ignored); err != nil {
		t.Fatalf("provider.closeSession after stop: %v", err)
	}
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
	threadItems := make(chan orchestration.ThreadStreamItem, 64)
	client := newRPCTestClient(t, s, rpcTestClientHandler{threadItems: threadItems})
	ctx := context.Background()
	threadID := orchestration.ThreadID("thread-metadata")

	var receipt orchestration.DispatchResult
	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-create-metadata", ThreadID: threadID, Title: "Metadata thread", ProviderInstanceID: "codex", Cwd: t.TempDir()}).Await(ctx, &receipt); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	var snapshot orchestration.ThreadStreamItem
	if err := client.Call(ctx, RPCMethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: threadID}).Await(ctx, &snapshot); err != nil {
		t.Fatalf("subscribeThread: %v", err)
	}
	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-turn-metadata", ThreadID: threadID, Message: &orchestration.CommandMessage{MessageID: "msg-metadata", Text: "hello"}}).Await(ctx, &receipt); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}

	// Session materialization publishes the agent's config options first.
	configEvent := waitForThreadEvent(t, threadItems, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadConfigOptionsUpdated
	})
	if value, ok := configOptionValue(configEvent.Payload.ConfigOptions, "mode"); !ok || value != "ask" {
		t.Fatalf("initial config options = %#v, want mode option with currentValue ask", configEvent.Payload.ConfigOptions)
	}
	if value, ok := configOptionValue(configEvent.Payload.ConfigOptions, "model"); !ok || value != "test-model-1" {
		t.Fatalf("initial config options = %#v, want model option with currentValue test-model-1", configEvent.Payload.ConfigOptions)
	}

	slashEvent := waitForThreadEvent(t, threadItems, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadSlashCommandsUpdated
	})
	if len(slashEvent.Payload.SlashCommands) != 1 || slashEvent.Payload.SlashCommands[0].Name != "compact" {
		t.Fatalf("slash commands = %#v, want the agent's compact command", slashEvent.Payload.SlashCommands)
	}

	waitForThreadEvent(t, threadItems, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadMetaUpdated && event.Payload.Title == "Agent set title"
	})

	usageEvent := waitForThreadEvent(t, threadItems, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadTokenUsageUpdated
	})
	usage := usageEvent.Payload.TokenUsage
	if usage == nil || usage.UsedTokens != 1200 || usage.MaxTokens != 200000 || usage.Cost != 0.42 || usage.Currency != "USD" {
		t.Fatalf("token usage = %#v, want used 1200 / max 200000 / cost 0.42 USD", usage)
	}

	waitForThreadEvent(t, threadItems, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadMessageSent && event.Payload.Role == orchestration.MessageRoleAssistant
	})

	// Model switching round-trips through session/set_config_option. Keeping the
	// category-specific case also verifies the thread's model projection.
	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadConfigOptionSet, CommandID: "cmd-model-metadata", ThreadID: threadID, OptionID: "model", Value: "test-model-2"}).Await(ctx, &receipt); err != nil {
		t.Fatalf("thread.config-option.set: %v", err)
	}
	waitForThreadEvent(t, threadItems, func(event orchestration.Event) bool {
		if event.Type != orchestration.EventThreadConfigOptionsUpdated {
			return false
		}
		value, ok := configOptionValue(event.Payload.ConfigOptions, "model")
		return ok && value == "test-model-2"
	})

	lateClient := newRPCTestClient(t, s, rpcTestClientHandler{})
	var late orchestration.ThreadStreamItem
	if err := lateClient.Call(ctx, RPCMethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: threadID}).Await(ctx, &late); err != nil {
		t.Fatalf("late subscribeThread: %v", err)
	}
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

func waitForThreadEvent(t *testing.T, items <-chan orchestration.ThreadStreamItem, match func(orchestration.Event) bool) orchestration.Event {
	t.Helper()
	deadline := time.After(3 * time.Second)
	for {
		select {
		case item := <-items:
			if item.Kind != "event" || item.Event == nil {
				continue
			}
			if match(*item.Event) {
				return *item.Event
			}
		case <-deadline:
			t.Fatal("timeout waiting for orchestration thread event")
		}
	}
}

func TestRPCSubscribeThreadSnapshotHasNoLiveGap(t *testing.T) {
	s := newTestServer(t)
	threadID := orchestration.ThreadID("thread-snapshot-race")
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "snapshot-race-create", ThreadID: threadID, Title: "initial"}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadMetaUpdate, CommandID: "snapshot-race-before", ThreadID: threadID, Title: "before-boundary"}); err != nil {
		t.Fatal(err)
	}

	client := &rpcClient{id: "client-snapshot-race", outbound: make(chan rpcOutbound, 4), done: make(chan struct{}), threadSubscriptions: make(map[orchestration.ThreadID]struct{})}
	s.rpcMu.Lock()
	s.rpcClients[client.id] = client
	s.rpcMu.Unlock()
	defer func() {
		s.rpcMu.Lock()
		delete(s.rpcClients, client.id)
		s.rpcMu.Unlock()
		client.closeOutbound()
		_ = s.Close()
	}()

	handler := &rpcHandler{server: s, client: client, afterThreadSnapshot: func(orchestration.ThreadID) {
		if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadMetaUpdate, CommandID: "snapshot-race-after", ThreadID: threadID, Title: "after-boundary"}); err != nil {
			t.Fatal(err)
		}
	}}
	req, err := jsonrpc2.NewCall(jsonrpc2.StringID("1"), RPCMethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: threadID})
	if err != nil {
		t.Fatal(err)
	}
	result, err := handler.Handle(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	item := result.(orchestration.ThreadStreamItem)
	if item.Snapshot == nil || item.Snapshot.Thread.Title != "before-boundary" {
		t.Fatalf("snapshot response = %#v", item)
	}

	select {
	case msg := <-client.outbound:
		if msg.method != RPCMethodOrchestrationSubscribeThread {
			t.Fatalf("notification method = %q, want subscribeThread", msg.method)
		}
		raw, ok := msg.params.(json.RawMessage)
		if !ok {
			t.Fatalf("notification params = %T, want pre-marshaled json.RawMessage", msg.params)
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
