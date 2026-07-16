package daemon

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/jsonrpc2"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
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

func newRPCTestClient(t *testing.T, s *Server, handler jsonrpc2.Handler) *jsonrpc2.Connection {
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

func TestRPCOrchestrationDispatchStreamsThreadEvents(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("codex", "codex", helperCommand("streaming-sessions")), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}

	threadItems := make(chan orchestration.ThreadStreamItem, 16)
	client := newRPCTestClient(t, s, rpcTestClientHandler{threadItems: threadItems})
	ctx := context.Background()

	threadID := orchestration.ThreadID("thread-stream")
	var receipt orchestration.DispatchResult
	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-create", ThreadID: threadID, Title: "Test thread", ProviderInstanceID: "codex", Cwd: t.TempDir()}).Await(ctx, &receipt); err != nil {
		t.Fatalf("thread.create: %v", err)
	}

	var snapshot orchestration.ThreadStreamItem
	if err := client.Call(ctx, RPCMethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: threadID}).Await(ctx, &snapshot); err != nil {
		t.Fatalf("subscribeThread: %v", err)
	}
	if snapshot.Kind != "snapshot" || snapshot.Snapshot == nil || snapshot.Snapshot.Thread.ID != threadID {
		t.Fatalf("snapshot = %#v, want thread snapshot", snapshot)
	}

	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-turn", ThreadID: threadID, Message: &orchestration.CommandMessage{MessageID: "msg-user", Text: "hello"}}).Await(ctx, &receipt); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}

	assistant := waitForThreadEvent(t, threadItems, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadMessageSent && event.Payload.Role == orchestration.MessageRoleAssistant
	})
	if assistant.Payload.Text != "hi" {
		t.Fatalf("assistant event = %#v, want hi", assistant)
	}

	var replay []orchestration.Event
	if err := client.Call(ctx, RPCMethodOrchestrationReplayEvents, orchestration.ReplayEventsInput{}).Await(ctx, &replay); err != nil {
		t.Fatalf("replayEvents: %v", err)
	}
	if len(replay) < 4 || replay[0].Sequence == 0 {
		t.Fatalf("replay = %#v, want orchestration events", replay)
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

func TestRPCSubscribeThreadStreamsEventsAppendedAfterSnapshot(t *testing.T) {
	s := newTestServer(t)
	threadID := orchestration.ThreadID("thread-subscribe-race")
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "create-subscribe-race", ThreadID: threadID, Title: "before"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}

	client := &rpcClient{id: "client-subscribe-race", outbound: make(chan rpcOutbound, 4), done: make(chan struct{}), threadSubscriptions: make(map[orchestration.ThreadID]struct{})}
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
		if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadMetaUpdate, CommandID: "meta-during-subscribe", ThreadID: threadID, Title: "during-subscribe"}); err != nil {
			t.Fatalf("thread.meta.update: %v", err)
		}
	}}
	req, err := jsonrpc2.NewCall(jsonrpc2.StringID("1"), RPCMethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: threadID})
	if err != nil {
		t.Fatalf("new call: %v", err)
	}

	result, err := handler.Handle(context.Background(), req)
	if err != nil {
		t.Fatalf("subscribeThread: %v", err)
	}
	snapshot := result.(orchestration.ThreadStreamItem)
	if snapshot.Kind != "snapshot" || snapshot.Snapshot == nil || snapshot.Snapshot.Thread.Title != "before" {
		t.Fatalf("snapshot = %#v, want pre-update thread snapshot", snapshot)
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
		var item orchestration.ThreadStreamItem
		if err := json.Unmarshal(raw, &item); err != nil {
			t.Fatalf("decode notification: %v", err)
		}
		if item.Kind != "event" || item.Event == nil || item.Event.Type != orchestration.EventThreadMetaUpdated || item.Event.Payload.Title != "during-subscribe" {
			t.Fatalf("notification = %s, want live meta update event", raw)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for live event appended after snapshot")
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

func TestRPCOrchestrationApprovalRespondResolvesProviderPermission(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("codex", "codex", helperCommand("permission-deny-sessions")), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}

	threadItems := make(chan orchestration.ThreadStreamItem, 16)
	client := newRPCTestClient(t, s, rpcTestClientHandler{threadItems: threadItems})
	ctx := context.Background()
	threadID := orchestration.ThreadID("thread-permission")

	var receipt orchestration.DispatchResult
	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-create-perm", ThreadID: threadID, Title: "Permission thread", ProviderInstanceID: "codex", Cwd: t.TempDir()}).Await(ctx, &receipt); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	var snapshot orchestration.ThreadStreamItem
	if err := client.Call(ctx, RPCMethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: threadID}).Await(ctx, &snapshot); err != nil {
		t.Fatalf("subscribeThread: %v", err)
	}

	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-turn-perm", ThreadID: threadID, Message: &orchestration.CommandMessage{MessageID: "msg-perm", Text: "hello"}}).Await(ctx, &receipt); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}

	approvalEvent := waitForThreadEvent(t, threadItems, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadApprovalOpened && event.Payload.Approval != nil
	})
	approvalPayload := approvalEvent.Payload.Approval
	if approvalPayload.RequestID == "" || len(approvalPayload.Options) == 0 {
		t.Fatalf("approval payload = %#v, want request with options", approvalPayload)
	}

	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadApprovalRespond, CommandID: "cmd-approval", ThreadID: threadID, RequestID: orchestration.ApprovalID(approvalPayload.RequestID), Decision: provider.ApprovalDecisionDecline}).Await(ctx, &receipt); err != nil {
		t.Fatalf("thread.approval.respond: %v", err)
	}

	resolved := waitForThreadEvent(t, threadItems, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadApprovalResolved && event.Payload.Approval != nil
	})
	resolvedPayload := resolved.Payload.Approval
	if resolvedPayload.Decision != provider.ApprovalDecisionDecline || resolvedPayload.OptionID != "reject" {
		t.Fatalf("resolved = %#v, want reject decline", resolvedPayload)
	}

	// The approval projection should also reflect the resolution on the thread.
	threadSnapshot, err := s.orchestration.ThreadSnapshot(threadID)
	if err != nil {
		t.Fatalf("thread snapshot: %v", err)
	}
	if len(threadSnapshot.Snapshot.Thread.Timeline.Approvals()) == 0 {
		t.Fatalf("thread approvals empty, want resolved approval projection")
	}
	approval := threadSnapshot.Snapshot.Thread.Timeline.Approvals()[0]
	if approval.Status != orchestration.ApprovalStatusResolved || approval.Decision != provider.ApprovalDecisionDecline {
		t.Fatalf("approval projection = %#v, want resolved decline", approval)
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
	if replay := s.orchestration.ReplayEvents(orchestration.ReplayEventsInput{}); len(replay) != 1 {
		t.Fatalf("replay events = %#v, want only client-created thread event", replay)
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
		"config":     map[string]any{"command": helperCommand("streaming-sessions")},
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
	summary := provider.SessionSummary{SessionID: "external-session", Title: "Imported session", UpdatedAt: "2026-07-15T12:00:00Z"}
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
	if subscribed.Snapshot == nil || subscribed.Snapshot.Thread.Draft || subscribed.Snapshot.Thread.Title != summary.Title || subscribed.Snapshot.Thread.Cwd == "" {
		t.Fatalf("imported snapshot = %+v", subscribed.Snapshot)
	}
	var receipt orchestration.DispatchResult
	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadSessionPrepare, CommandID: "prepare-imported", ThreadID: first.ThreadID}).Await(ctx, &receipt); err != nil {
		t.Fatalf("prepare imported thread: %v", err)
	}
	waitForThreadEvent(t, threadItems, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadHistoryReplayCompleted
	})
	var replayed orchestration.ThreadStreamItem
	if err := client.Call(ctx, RPCMethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: first.ThreadID}).Await(ctx, &replayed); err != nil {
		t.Fatalf("resubscribe imported thread: %v", err)
	}
	encoded, err := json.Marshal(replayed.Snapshot.Thread.Timeline)
	if err != nil {
		t.Fatalf("encode replayed timeline: %v", err)
	}
	if !strings.Contains(string(encoded), "replayed") {
		t.Fatalf("imported timeline = %s, want provider replay", encoded)
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
// agents emit during a prompt: slash commands, an
// agent-set title, token usage, session config options, and provider-owned
// Provider mode and other config-option switching round-trip.
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

	// Provider modes use the same config-option path as every other session option.
	if err := client.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{Type: orchestration.CommandThreadConfigOptionSet, CommandID: "cmd-mode-metadata", ThreadID: threadID, OptionID: "mode", Value: "plan"}).Await(ctx, &receipt); err != nil {
		t.Fatalf("set mode config option: %v", err)
	}
	waitForThreadEvent(t, threadItems, func(event orchestration.Event) bool {
		if event.Type != orchestration.EventThreadConfigOptionsUpdated {
			return false
		}
		value, ok := configOptionValue(event.Payload.ConfigOptions, "mode")
		return ok && value == "plan"
	})

	// Config-option switching round-trips through session/set_config_option.
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

	// The same state must be projected onto the thread for late subscribers.
	thread, ok := s.orchestration.Thread(threadID)
	if !ok {
		t.Fatalf("thread %q missing after turn", threadID)
	}
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
	if value, ok := configOptionValue(thread.Session.ConfigOptions, "mode"); !ok || value != "plan" {
		t.Fatalf("session config options = %#v, want mode plan", thread.Session.ConfigOptions)
	}
	if value, ok := configOptionValue(thread.Session.ConfigOptions, "model"); !ok || value != "test-model-2" {
		t.Fatalf("session config options = %#v, want model test-model-2", thread.Session.ConfigOptions)
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
