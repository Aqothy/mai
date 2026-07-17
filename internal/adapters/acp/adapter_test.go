package acp

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	acp "github.com/Aqothy/go-acp"
	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/provider"
)

// --- wire-level fake agent --------------------------------------------------
//
// The Instance is tested against a fake agent speaking raw newline-delimited
// JSON-RPC over in-memory pipes, exactly like a real agent process on stdio.
// Hooks run one goroutine per inbound message, so a blocked session/prompt
// never stalls session/cancel — the concurrency shape real agents have and the
// steering/interrupt behavior locks depend on.

type wireMsg struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  json.RawMessage `json:"error,omitempty"`
}

type wireSessionParams struct {
	SessionID string `json:"sessionId"`
	Cwd       string `json:"cwd"`
	Cursor    string `json:"cursor"`
	ConfigID  string `json:"configId"`
	Type      string `json:"type"`
	Value     any    `json:"value"`
	ModeID    string `json:"modeId"`
	MethodID  string `json:"methodId"`
	Prompt    []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"prompt"`
}

// stringValue returns the wire value as a string ("" for non-strings), for
// hooks that echo a select value back into a config-options payload.
func (p wireSessionParams) stringValue() string {
	s, _ := p.Value.(string)
	return s
}

type fakeWireAgent struct {
	t  *testing.T
	mu sync.Mutex
	r  io.Closer
	w  io.WriteCloser
	// responses receives replies to requests initiated by the fake agent. Most
	// tests leave it nil because they only exercise client-initiated RPCs.
	responses chan wireMsg

	capabilities map[string]any
	authMethods  []any

	onNewSession      func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams)
	onLoadSession     func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams)
	onResumeSession   func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams)
	onPrompt          func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams)
	onCancel          func(a *fakeWireAgent, params wireSessionParams)
	onSetConfigOption func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams)
	onSetMode         func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams)
	onListSessions    func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams)
	onCloseSession    func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams)
}

func (a *fakeWireAgent) write(msg map[string]any) {
	a.mu.Lock()
	defer a.mu.Unlock()
	raw, err := json.Marshal(msg)
	if err != nil {
		a.t.Errorf("fake agent marshal: %v", err)
		return
	}
	if _, err := a.w.Write(append(raw, '\n')); err != nil && !strings.Contains(err.Error(), "closed pipe") {
		a.t.Logf("fake agent write: %v", err)
	}
}

func (a *fakeWireAgent) closeTransport() {
	if a.r != nil {
		_ = a.r.Close()
	}
	if a.w != nil {
		_ = a.w.Close()
	}
}

func (a *fakeWireAgent) respond(id json.RawMessage, result any) {
	a.write(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
}

func (a *fakeWireAgent) respondError(id json.RawMessage, code int, message string) {
	a.write(map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": code, "message": message}})
}

func (a *fakeWireAgent) sendUpdate(sessionID string, update map[string]any) {
	a.write(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"sessionId": sessionID, "update": update}})
}

func agentMessageUpdate(messageID string, text string) map[string]any {
	update := map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": text}}
	if messageID != "" {
		update["messageId"] = messageID
	}
	return update
}

func (a *fakeWireAgent) serve(r io.Reader) {
	reader := bufio.NewReader(r)
	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			return
		}
		var msg wireMsg
		if err := json.Unmarshal(line, &msg); err != nil {
			a.t.Errorf("fake agent decode %s: %v", line, err)
			continue
		}
		go a.dispatch(msg)
	}
}

func (a *fakeWireAgent) dispatch(msg wireMsg) {
	if msg.Method == "" {
		if len(msg.ID) > 0 && a.responses != nil {
			a.responses <- msg
		}
		return
	}
	var params wireSessionParams
	if len(msg.Params) > 0 {
		_ = json.Unmarshal(msg.Params, &params)
	}
	switch msg.Method {
	case "initialize":
		capabilities := a.capabilities
		if capabilities == nil {
			capabilities = map[string]any{}
		}
		authMethods := a.authMethods
		if authMethods == nil {
			authMethods = []any{}
		}
		a.respond(msg.ID, map[string]any{"protocolVersion": 1, "agentCapabilities": capabilities, "agentInfo": map[string]any{"name": "fake-wire-agent", "version": "0"}, "authMethods": authMethods})
	case "session/new":
		if a.onNewSession != nil {
			a.onNewSession(a, msg.ID, params)
			return
		}
		a.respond(msg.ID, map[string]any{"sessionId": "sess"})
	case "session/load":
		if a.onLoadSession != nil {
			a.onLoadSession(a, msg.ID, params)
			return
		}
		a.respond(msg.ID, map[string]any{})
	case "session/resume":
		if a.onResumeSession != nil {
			a.onResumeSession(a, msg.ID, params)
			return
		}
		a.respond(msg.ID, map[string]any{})
	case "session/prompt":
		if a.onPrompt != nil {
			a.onPrompt(a, msg.ID, params)
			return
		}
		a.respond(msg.ID, map[string]any{"stopReason": "end_turn"})
	case "session/cancel":
		if a.onCancel != nil {
			a.onCancel(a, params)
		}
	case "session/set_config_option":
		if a.onSetConfigOption != nil {
			a.onSetConfigOption(a, msg.ID, params)
			return
		}
		a.respond(msg.ID, map[string]any{"configOptions": []any{}})
	case "session/set_mode":
		if a.onSetMode != nil {
			a.onSetMode(a, msg.ID, params)
			return
		}
		a.respond(msg.ID, map[string]any{})
	case "session/close":
		if a.onCloseSession != nil {
			a.onCloseSession(a, msg.ID, params)
			return
		}
		a.respond(msg.ID, map[string]any{})
	case "authenticate", "logout", "session/delete":
		a.respond(msg.ID, map[string]any{})
	case "session/list":
		if a.onListSessions != nil {
			a.onListSessions(a, msg.ID, params)
			return
		}
		a.respond(msg.ID, map[string]any{"sessions": []any{}})
	case "$/cancel_request":
		// Protocol-level request cancellation; nothing to do in the fake.
	default:
		if len(msg.ID) > 0 {
			a.respondError(msg.ID, -32601, "method not found")
		}
	}
}

func TestFilesystemAndTerminalClientMethodsRemainUnsupported(t *testing.T) {
	agent := &fakeWireAgent{responses: make(chan wireMsg, 7)}
	newWireTestHandle(t, agent)

	requests := []struct {
		id     string
		method string
		params map[string]any
	}{
		{id: "fs-read", method: "fs/read_text_file", params: map[string]any{"sessionId": "sess", "path": "/tmp/file"}},
		{id: "fs-write", method: "fs/write_text_file", params: map[string]any{"sessionId": "sess", "path": "/tmp/file", "content": "nope"}},
		{id: "terminal-create", method: "terminal/create", params: map[string]any{"sessionId": "sess", "command": "pwd"}},
		{id: "terminal-output", method: "terminal/output", params: map[string]any{"sessionId": "sess", "terminalId": "term"}},
		{id: "terminal-wait", method: "terminal/wait_for_exit", params: map[string]any{"sessionId": "sess", "terminalId": "term"}},
		{id: "terminal-kill", method: "terminal/kill", params: map[string]any{"sessionId": "sess", "terminalId": "term"}},
		{id: "terminal-release", method: "terminal/release", params: map[string]any{"sessionId": "sess", "terminalId": "term"}},
	}
	for _, request := range requests {
		agent.write(map[string]any{"jsonrpc": "2.0", "id": request.id, "method": request.method, "params": request.params})
	}

	seen := make(map[string]struct{}, len(requests))
	for range requests {
		select {
		case response := <-agent.responses:
			responseID := strings.Trim(string(response.ID), `"`)
			if _, duplicate := seen[responseID]; duplicate {
				t.Fatalf("duplicate response for unsupported client method %q", responseID)
			}
			seen[responseID] = struct{}{}
			var rpcErr struct {
				Code int `json:"code"`
			}
			if err := json.Unmarshal(response.Error, &rpcErr); err != nil {
				t.Fatalf("decode response error: %v", err)
			}
			if rpcErr.Code != -32601 {
				t.Fatalf("response %s error = %s, want MethodNotFound", response.ID, response.Error)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("timed out waiting for unsupported client-method response")
		}
	}
	for _, request := range requests {
		if _, ok := seen[request.id]; !ok {
			t.Errorf("missing response for unsupported client method %q", request.id)
		}
	}
}

// eventRecorder collects runtime events emitted from consumer goroutines.
type eventRecorder struct {
	mu     sync.Mutex
	events []provider.RuntimeEvent
}

func (r *eventRecorder) listener(event provider.RuntimeEvent) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, event)
}

func (r *eventRecorder) snapshot() []provider.RuntimeEvent {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]provider.RuntimeEvent(nil), r.events...)
}

// newWireTestHandle connects a Instance to the fake agent over in-memory pipes
// and runs the real initialize handshake.
func newWireTestHandle(t *testing.T, agent *fakeWireAgent) *Instance {
	t.Helper()
	agent.t = t

	agentIn, clientOut := io.Pipe() // client -> agent
	clientIn, agentOut := io.Pipe() // agent -> client
	agent.r = agentIn
	agent.w = agentOut
	go agent.serve(agentIn)

	h := newInstance(nil)
	if err := h.connectClient(acp.Combine(clientIn, clientOut), slog.Default()); err != nil {
		t.Fatalf("connect fake agent: %v", err)
	}
	t.Cleanup(func() {
		h.cancel()
		_ = h.conn.Close()
		_ = agentIn.Close()
		_ = agentOut.Close()
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	initResp, err := h.initializeConnection(ctx)
	if err != nil {
		t.Fatalf("initialize fake agent: %v", err)
	}
	h.info = provider.InstanceInfo{
		InstanceID:   "acp-test",
		Name:         "ACP Test",
		Driver:       DriverKind,
		Capabilities: capabilitySet(initResp),
		Auth:         authStateFromACP(initResp),
	}
	return h
}

// bindTestSession materializes the session struct (like bindSession) and
// returns it so tests can seed per-session state directly.
func bindTestSession(h *Instance, threadID string, sessionID string) *acpSession {
	h.bindSession(threadID, sessionID)
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.sessions[sessionID]
}

// callRecorder captures config calls made by the handle.
type callRecorder struct {
	mu             sync.Mutex
	setConfigCalls []wireSessionParams
}

func (r *callRecorder) recordConfig(params wireSessionParams) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.setConfigCalls = append(r.setConfigCalls, params)
}

func (r *callRecorder) configCalls() []wireSessionParams {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]wireSessionParams(nil), r.setConfigCalls...)
}

func wireModeConfigOptions(current string) []any {
	return []any{map[string]any{
		"type": "select", "id": "interaction-mode", "name": "Mode", "category": "mode", "currentValue": current,
		"options": []any{
			map[string]any{"value": "code", "name": "Code"},
			map[string]any{"value": "architect", "name": "Architect"},
		},
	}}
}

func wireModelConfigOptions(current string) []any {
	return []any{map[string]any{
		"type": "select", "id": "model", "name": "Model", "category": "model", "currentValue": current,
		"options": []any{
			map[string]any{"value": "model-a", "name": "Model A"},
			map[string]any{"value": "model-b", "name": "Model B"},
		},
	}}
}

// --- conversion / pure unit tests -------------------------------------------

func TestContentBlocksRejectRawAttachments(t *testing.T) {
	_, err := contentBlocks(provider.SendTurnInput{
		Input: "hello",
		Attachments: []provider.Attachment{{
			Raw: json.RawMessage(`{"type":"text","text":"from raw"}`),
		}},
	}, provider.PromptContentCapabilities{})
	if err == nil {
		t.Fatal("contentBlocks raw attachment err = nil, want rejection")
	}
}

func TestContentBlocksMapEmbeddedResourceWhenAdvertised(t *testing.T) {
	input := provider.SendTurnInput{Attachments: []provider.Attachment{{Kind: "resource", URI: "file:///tmp/context.txt", MimeType: "text/plain", Data: "context"}}}
	if _, err := contentBlocks(input, provider.PromptContentCapabilities{}); err == nil {
		t.Fatal("expected embedded resource to require capability")
	}
	blocks, err := contentBlocks(input, provider.PromptContentCapabilities{EmbeddedContext: true})
	if err != nil {
		t.Fatalf("contentBlocks embedded resource: %v", err)
	}
	if len(blocks) != 1 || blocks[0].Type != schema.ContentBlockTypeResource || blocks[0].Resource == nil || blocks[0].Resource.URI != "file:///tmp/context.txt" || blocks[0].Resource.Text == nil || *blocks[0].Resource.Text != "context" {
		t.Fatalf("blocks = %#v, want one embedded text resource", blocks)
	}
}

func TestContentBlocksGateImageOnCapability(t *testing.T) {
	imageInput := provider.SendTurnInput{Attachments: []provider.Attachment{{Kind: "image", Data: "base64data", MimeType: "image/png"}}}

	if _, err := contentBlocks(imageInput, provider.PromptContentCapabilities{}); err == nil {
		t.Fatal("expected error when image content is not supported")
	}

	blocks, err := contentBlocks(imageInput, provider.PromptContentCapabilities{Image: true})
	if err != nil {
		t.Fatalf("contentBlocks with image capability: %v", err)
	}
	if len(blocks) != 1 || blocks[0].Type != schema.ContentBlockTypeImage || blocks[0].Data == nil || *blocks[0].Data != "base64data" || blocks[0].MimeType == nil || *blocks[0].MimeType != "image/png" {
		t.Fatalf("blocks = %#v, want one image block", blocks)
	}
}

func permissionOptions() []schema.PermissionOption {
	return []schema.PermissionOption{
		{Kind: schema.PermissionOptionKindAllowOnce, Name: "Allow", OptionID: "allow"},
		{Kind: schema.PermissionOptionKindRejectOnce, Name: "Reject", OptionID: "reject"},
	}
}

func permissionOptionsWithAllowAlways() []schema.PermissionOption {
	return []schema.PermissionOption{
		{Kind: schema.PermissionOptionKindAllowOnce, Name: "Allow once", OptionID: "allow-once"},
		{Kind: schema.PermissionOptionKindAllowAlways, Name: "Allow always", OptionID: "allow-always"},
		{Kind: schema.PermissionOptionKindRejectOnce, Name: "Reject", OptionID: "reject"},
	}
}

func selectedOption(resp schema.RequestPermissionResponse) string {
	optionID, ok := selectedPermissionOptionID(resp)
	if !ok {
		return ""
	}
	return string(optionID)
}

func TestAuthCapabilityOnlyCountsStableAgentAuthMethods(t *testing.T) {
	var unstable []schema.AuthMethod
	if err := json.Unmarshal([]byte(`[{"type":"env_var","id":"env-login","name":"Env","vars":[]},{"type":"terminal","id":"terminal-login","name":"Terminal"}]`), &unstable); err != nil {
		t.Fatalf("decode unstable auth methods: %v", err)
	}

	initResp := schema.InitializeResponse{AuthMethods: unstable}
	if capabilitySet(initResp).Auth {
		t.Fatal("unstable-only auth methods should not advertise daemon auth support")
	}
	if auth := authStateFromACP(initResp); auth.Status != provider.AuthStatusUnknown || len(auth.Methods) != 0 {
		t.Fatalf("auth state = %#v, want unknown with no invokable methods", auth)
	}
	if _, err := (&Instance{initialize: initResp}).resolveAuthMethodID("env-login"); err == nil {
		t.Fatal("resolve unstable auth method err = nil")
	}

	var stable []schema.AuthMethod
	if err := json.Unmarshal([]byte(`[{"id":"agent-login","name":"Agent"}]`), &stable); err != nil {
		t.Fatalf("decode stable auth method: %v", err)
	}
	initResp = schema.InitializeResponse{AuthMethods: stable}
	if !capabilitySet(initResp).Auth {
		t.Fatal("agent auth method should advertise daemon auth support")
	}
	// Advertised methods mean auth is available, not required: agents like
	// claude-code-acp advertise their login method even while authenticated.
	if auth := authStateFromACP(initResp); auth.Status != provider.AuthStatusUnknown || len(auth.Methods) != 1 {
		t.Fatalf("auth state = %#v, want unknown with the invokable method", auth)
	}
	if got, err := (&Instance{initialize: initResp}).resolveAuthMethodID("agent-login"); err != nil || got != "agent-login" {
		t.Fatalf("resolve stable auth method = %q, %v", got, err)
	}
}

func TestSessionUpdateMapsUsageUpdate(t *testing.T) {
	var notification schema.SessionNotification
	if err := json.Unmarshal([]byte(`{"sessionId":"sess","update":{"sessionUpdate":"usage_update","used":12,"size":100,"cost":{"amount":0.5,"currency":"USD"}}}`), &notification); err != nil {
		t.Fatalf("decode usage update: %v", err)
	}
	event := sessionRuntimeEvent(notification)
	if event.Type != provider.RuntimeEventThreadTokenUsage || len(event.Payload.Data) == 0 {
		t.Fatalf("event = %#v, want token usage payload", event)
	}
	if event.Payload.TokenUsage == nil || event.Payload.TokenUsage.UsedTokens != 12 || event.Payload.TokenUsage.MaxTokens != 100 || event.Payload.TokenUsage.Cost != 0.5 {
		t.Fatalf("token usage = %#v, want used/max/cost mapped", event.Payload.TokenUsage)
	}
	if event.Payload.TokenUsage.Currency != "USD" {
		t.Fatalf("token usage currency = %q, want USD", event.Payload.TokenUsage.Currency)
	}
	var raw schema.UsageUpdate
	if err := json.Unmarshal(event.Payload.Data, &raw); err != nil {
		t.Fatalf("decode raw usage payload: %v", err)
	}
	if raw.Used != 12 || raw.Size != 100 || raw.Cost == nil || raw.Cost.Amount != 0.5 || raw.Cost.Currency != "USD" {
		t.Fatalf("raw usage payload = %#v, want complete ACP usage update", raw)
	}
}

func TestSessionUpdateMapsEmptyAvailableCommands(t *testing.T) {
	var notification schema.SessionNotification
	if err := json.Unmarshal([]byte(`{"sessionId":"sess","update":{"sessionUpdate":"available_commands_update","availableCommands":[]}}`), &notification); err != nil {
		t.Fatalf("decode available commands update: %v", err)
	}
	event := sessionRuntimeEvent(notification)
	if event.Type != provider.RuntimeEventThreadMetadataUpdate || event.Payload.SlashCommands == nil || len(event.Payload.SlashCommands) != 0 {
		t.Fatalf("event = %#v, want explicit empty slash-command update", event)
	}
	raw, err := json.Marshal(event.Payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	var payload map[string]json.RawMessage
	if err := json.Unmarshal(raw, &payload); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	if string(payload["slashCommands"]) != "[]" {
		t.Fatalf("payload JSON = %s, want slashCommands:[]", raw)
	}
}

func TestSessionUpdateMapsToolCallUpdateEmptyReplacementFields(t *testing.T) {
	var notification schema.SessionNotification
	if err := json.Unmarshal([]byte(`{"sessionId":"sess","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool-1","content":[],"locations":[]}}`), &notification); err != nil {
		t.Fatalf("decode tool-call update: %v", err)
	}
	event := sessionRuntimeEvent(notification)
	if event.Type != provider.RuntimeEventItemUpdated || event.Payload.Data == nil {
		t.Fatalf("event = %#v, want item update with data", event)
	}
	var data map[string]json.RawMessage
	if err := json.Unmarshal(event.Payload.Data, &data); err != nil {
		t.Fatalf("unmarshal tool-call update data: %v", err)
	}
	if string(data["content"]) != `[]` || string(data["locations"]) != `[]` {
		t.Fatalf("tool-call update data = %s, want explicit empty content and locations", event.Payload.Data)
	}
	if _, ok := data["kind"]; ok {
		t.Fatalf("tool-call update data = %s, want omitted kind to stay absent", event.Payload.Data)
	}
}

func TestSessionUpdateMapsNonTextAssistantContent(t *testing.T) {
	var notification schema.SessionNotification
	if err := json.Unmarshal([]byte(`{"sessionId":"sess","update":{"sessionUpdate":"agent_message_chunk","messageId":"msg_1","content":{"type":"image","data":"base64","mimeType":"image/png"}}}`), &notification); err != nil {
		t.Fatalf("decode image message update: %v", err)
	}
	event := sessionRuntimeEvent(notification)
	if event.Type != provider.RuntimeEventContentDelta || event.ItemID != "msg_1" || event.Payload.Delta != "" || event.Payload.StreamKind != provider.RuntimeContentAssistantText || len(event.Payload.Attachments) != 1 || event.Payload.Attachments[0].Kind != "image" || event.Payload.Attachments[0].Data != "base64" || event.Payload.Attachments[0].MimeType != "image/png" {
		t.Fatalf("event = %#v, want image attachment preserved", event)
	}
}

func TestSessionUpdateMapsMessageID(t *testing.T) {
	var notification schema.SessionNotification
	if err := json.Unmarshal([]byte(`{"sessionId":"sess","update":{"sessionUpdate":"agent_message_chunk","messageId":"msg_1","content":{"type":"text","text":"hi"}}}`), &notification); err != nil {
		t.Fatalf("decode message update: %v", err)
	}
	event := sessionRuntimeEvent(notification)
	if event.ItemID != "msg_1" || event.Payload.Delta != "hi" || event.Payload.StreamKind != provider.RuntimeContentAssistantText {
		t.Fatalf("event = %#v", event)
	}
}

func TestSessionUpdateMapsPlanAsGenericData(t *testing.T) {
	var notification schema.SessionNotification
	if err := json.Unmarshal([]byte(`{"sessionId":"sess","update":{"sessionUpdate":"plan","entries":[{"content":"Do it","priority":"high","status":"pending"}]}}`), &notification); err != nil {
		t.Fatalf("decode plan update: %v", err)
	}
	event := sessionRuntimeEvent(notification)
	if event.Type != provider.RuntimeEventTurnPlanUpdated || len(event.Payload.Data) == 0 {
		t.Fatalf("event = %#v, want generic plan data", event)
	}
	if len(event.Payload.PlanEntries) != 1 || event.Payload.PlanEntries[0].Content != "Do it" {
		t.Fatalf("plan entries = %#v", event.Payload.PlanEntries)
	}
	entry := event.Payload.PlanEntries[0]
	if string(entry.Priority) != "high" || string(entry.Status) != "pending" {
		t.Fatalf("plan entry = %#v, want high-priority pending entry", entry)
	}
	var raw schema.Plan
	if err := json.Unmarshal(event.Payload.Data, &raw); err != nil {
		t.Fatalf("decode raw plan payload: %v", err)
	}
	if len(raw.Entries) != 1 || raw.Entries[0].Content != "Do it" || string(raw.Entries[0].Priority) != "high" || string(raw.Entries[0].Status) != "pending" {
		t.Fatalf("raw plan payload = %#v, want complete ACP plan", raw)
	}
}

func testSessionNotification(t *testing.T, raw string) schema.SessionNotification {
	t.Helper()
	var notification schema.SessionNotification
	if err := json.Unmarshal([]byte(raw), &notification); err != nil {
		t.Fatalf("decode session notification: %v", err)
	}
	return notification
}

func testAgentMessageUpdate(t *testing.T, sessionID string, messageID string, text string) schema.SessionNotification {
	t.Helper()
	return testSessionNotification(t, fmt.Sprintf(`{"sessionId":%q,"update":{"sessionUpdate":"agent_message_chunk","messageId":%q,"content":{"type":"text","text":%q}}}`, sessionID, messageID, text))
}

func TestHandleSessionUpdateSuppressesLiveUserPromptEcho(t *testing.T) {
	var events []provider.RuntimeEvent
	h := newInstance(func(event provider.RuntimeEvent) { events = append(events, event) })
	bindTestSession(h, "thread-1", "sess").collector = &promptCollector{threadID: "thread-1", turnID: "turn-1"}
	h.handleACPSessionUpdate(testSessionNotification(t, `{"sessionId":"sess","update":{"sessionUpdate":"user_message_chunk","messageId":"echo","content":{"type":"text","text":"hello"}}}`))
	if len(events) != 0 {
		t.Fatalf("events = %#v, want live user prompt echo suppressed", events)
	}
}

func TestHandleSessionUpdateScopesACPItemIDsBySession(t *testing.T) {
	var events []provider.RuntimeEvent
	h := newInstance(func(event provider.RuntimeEvent) { events = append(events, event) })
	bindTestSession(h, "thread-1", "sess-a")
	bindTestSession(h, "thread-2", "sess-b")

	for _, sessionID := range []string{"sess-a", "sess-b"} {
		notification := testSessionNotification(t, fmt.Sprintf(`{"sessionId":%q,"update":{"sessionUpdate":"tool_call","toolCallId":"tool-1","title":"Run tests","kind":"execute","status":"pending"}}`, sessionID))
		h.handleACPSessionUpdate(notification)
	}
	if len(events) != 2 {
		t.Fatalf("events = %#v, want two tool-call events", events)
	}
	if events[0].ItemID == "" || events[1].ItemID == "" || events[0].ItemID == events[1].ItemID {
		t.Fatalf("tool item ids = %q, %q; want session-scoped distinct ids", events[0].ItemID, events[1].ItemID)
	}
	if strings.Contains(events[0].ItemID, "sess-a") || strings.Contains(events[1].ItemID, "sess-b") {
		t.Fatalf("scoped item ids leak native session ids: %q, %q", events[0].ItemID, events[1].ItemID)
	}

	events = nil
	h.handleACPSessionUpdate(testAgentMessageUpdate(t, "sess-a", "msg-1", "hello"))
	h.handleACPSessionUpdate(testAgentMessageUpdate(t, "sess-b", "msg-1", "world"))
	if len(events) != 2 {
		t.Fatalf("message events = %#v, want two assistant message events", events)
	}
	if events[0].ItemID == "" || events[1].ItemID == "" || events[0].ItemID == events[1].ItemID {
		t.Fatalf("assistant item ids = %q, %q; want session-scoped distinct ids", events[0].ItemID, events[1].ItemID)
	}
}

// Regression (audited leak): stray updates draining from a disposed stream
// after unbind must not re-materialize per-session state (scope entries,
// config caches, tool states) for the dead session.
func TestStrayUpdatesAfterUnbindDoNotRecreateSessionState(t *testing.T) {
	recorder := &eventRecorder{}
	h := newInstance(recorder.listener)
	bindTestSession(h, "thread-1", "sess")
	h.unbindSessionID("sess")

	h.handleACPSessionUpdate(testSessionNotification(t, `{"sessionId":"sess","update":{"sessionUpdate":"tool_call","toolCallId":"tool-1","title":"Run","kind":"execute","status":"pending"}}`))
	h.handleACPSessionUpdate(testSessionNotification(t, `{"sessionId":"sess","update":{"sessionUpdate":"config_option_update","configOptions":[]}}`))
	h.handleACPSessionUpdate(testAgentMessageUpdate(t, "sess", "msg-1", "stray"))

	h.mu.Lock()
	session := h.sessions["sess"]
	bound := h.sessionsByThread["thread-1"]
	h.mu.Unlock()
	if session != nil || bound != "" {
		t.Fatalf("stray updates re-created state for dead session: session=%#v bound=%q", session, bound)
	}
	if events := recorder.snapshot(); len(events) != 0 {
		t.Fatalf("stray updates for dead session were published: %#v", events)
	}
}

func TestPermissionOpenWaitsForPriorSessionUpdates(t *testing.T) {
	agent := &fakeWireAgent{}
	h := newWireTestHandle(t, agent)
	recorder := &eventRecorder{}
	updateEntered := make(chan struct{})
	releaseUpdate := make(chan struct{})
	defer func() {
		select {
		case <-releaseUpdate:
		default:
			close(releaseUpdate)
		}
	}()
	opened := make(chan string, 1)
	h.runtimeEventListener = func(event provider.RuntimeEvent) {
		recorder.listener(event)
		switch event.Type {
		case provider.RuntimeEventContentDelta:
			close(updateEntered)
			<-releaseUpdate
		case provider.RuntimeEventRequestOpened:
			opened <- event.RequestID
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, err := h.StartSession(ctx, provider.StartSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	h.mu.Lock()
	h.sessionForThreadLocked("thread-1").collector = &promptCollector{threadID: "thread-1", turnID: "turn-1"}
	h.mu.Unlock()

	agent.sendUpdate("sess", agentMessageUpdate("msg-1", "explanation"))
	select {
	case <-updateEntered:
	case <-time.After(time.Second):
		t.Fatal("prior session update did not enter the stream consumer")
	}

	permissionDone := make(chan schema.RequestPermissionResponse, 1)
	go func() {
		resp, _ := h.requestPermission(context.Background(), schema.RequestPermissionRequest{SessionID: "sess", ToolCall: schema.ToolCallUpdate{ToolCallID: "tool-1"}, Options: permissionOptions()})
		permissionDone <- resp
	}()
	select {
	case requestID := <-opened:
		t.Fatalf("approval %q overtook the blocked prior session update", requestID)
	case <-time.After(50 * time.Millisecond):
	}

	close(releaseUpdate)
	var requestID string
	select {
	case requestID = <-opened:
	case <-time.After(time.Second):
		t.Fatal("approval was not published after the prior update drained")
	}
	if err := h.RespondToRequest(context.Background(), provider.RespondToRequestInput{ThreadID: "thread-1", RequestID: requestID, Decision: provider.ApprovalDecisionAccept}); err != nil {
		t.Fatalf("RespondToRequest: %v", err)
	}
	select {
	case resp := <-permissionDone:
		if selectedOption(resp) != "allow" {
			t.Fatalf("permission outcome = %#v, want allow", resp.Outcome)
		}
	case <-time.After(time.Second):
		t.Fatal("permission response did not complete")
	}

	events := recorder.snapshot()
	if len(events) < 2 || events[0].Type != provider.RuntimeEventContentDelta || events[1].Type != provider.RuntimeEventRequestOpened {
		t.Fatalf("events = %#v, want session update before permission open", events)
	}
}

func TestTerminalToolUpdateCancelsPendingPermission(t *testing.T) {
	opened := make(chan string, 1)
	terminalPublished := make(chan struct{}, 1)
	releaseTerminal := make(chan struct{})
	recorder := &eventRecorder{}
	h := newInstance(nil)
	bindTestSession(h, "thread-1", "sess").collector = &promptCollector{threadID: "thread-1", turnID: "turn-1"}
	h.runtimeEventListener = func(event provider.RuntimeEvent) {
		recorder.listener(event)
		if event.Type == provider.RuntimeEventRequestOpened {
			opened <- event.RequestID
		}
		if event.Type == provider.RuntimeEventItemUpdated && event.Payload.ItemStatus == provider.ItemStatusCompleted {
			terminalPublished <- struct{}{}
			<-releaseTerminal
		}
	}

	done := make(chan schema.RequestPermissionResponse, 1)
	go func() {
		resp, _ := h.requestPermission(context.Background(), schema.RequestPermissionRequest{SessionID: "sess", ToolCall: schema.ToolCallUpdate{ToolCallID: "tool_1"}, Options: permissionOptions()})
		done <- resp
	}()
	requestID := <-opened
	handled := make(chan struct{})
	go func() {
		h.handleACPSessionUpdate(testSessionNotification(t, `{"sessionId":"sess","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool_1","status":"completed"}}`))
		close(handled)
	}()
	<-terminalPublished
	if err := h.RespondToRequest(context.Background(), provider.RespondToRequestInput{ThreadID: "thread-1", RequestID: requestID, Decision: provider.ApprovalDecisionAccept}); err == nil {
		t.Fatal("RespondToRequest accepted approval after the terminal tool event was published")
	}
	close(releaseTerminal)
	<-handled

	select {
	case resp := <-done:
		if resp.Outcome.Outcome != schema.RequestPermissionOutcomeOutcomeCancelled {
			t.Fatalf("permission outcome = %#v, want cancelled", resp.Outcome)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("terminal tool update did not resolve pending permission")
	}
	foundResolved := false
	for _, event := range recorder.snapshot() {
		if event.Type == provider.RuntimeEventRequestResolved && event.Payload.Cancelled {
			foundResolved = true
		}
	}
	if !foundResolved {
		t.Fatalf("events = %#v, want cancelled request resolution", recorder.snapshot())
	}
}

func TestTerminalToolUpdateOverridesQueuedApproval(t *testing.T) {
	opened := make(chan string, 1)
	releaseOpened := make(chan struct{})
	terminalPublished := make(chan struct{}, 1)
	releaseTerminal := make(chan struct{})
	h := newInstance(nil)
	bindTestSession(h, "thread-1", "sess").collector = &promptCollector{threadID: "thread-1", turnID: "turn-1"}
	h.runtimeEventListener = func(event provider.RuntimeEvent) {
		switch {
		case event.Type == provider.RuntimeEventRequestOpened:
			opened <- event.RequestID
			<-releaseOpened
		case event.Type == provider.RuntimeEventItemUpdated && event.Payload.ItemStatus == provider.ItemStatusCompleted:
			terminalPublished <- struct{}{}
			<-releaseTerminal
		}
	}

	done := make(chan schema.RequestPermissionResponse, 1)
	go func() {
		resp, _ := h.requestPermission(context.Background(), schema.RequestPermissionRequest{SessionID: "sess", ToolCall: schema.ToolCallUpdate{ToolCallID: "tool_1"}, Options: permissionOptions()})
		done <- resp
	}()
	requestID := <-opened
	if err := h.RespondToRequest(context.Background(), provider.RespondToRequestInput{ThreadID: "thread-1", RequestID: requestID, Decision: provider.ApprovalDecisionAccept}); err != nil {
		t.Fatalf("RespondToRequest before terminal update: %v", err)
	}
	handled := make(chan struct{})
	go func() {
		h.handleACPSessionUpdate(testSessionNotification(t, `{"sessionId":"sess","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool_1","status":"completed"}}`))
		close(handled)
	}()
	<-terminalPublished
	close(releaseOpened)
	resp := <-done
	if resp.Outcome.Outcome != schema.RequestPermissionOutcomeOutcomeCancelled {
		t.Fatalf("permission outcome = %#v, want terminal update to override queued approval", resp.Outcome)
	}
	close(releaseTerminal)
	<-handled
}

func TestPermissionCancelsWhenToolSettledBeforeRequestRegistration(t *testing.T) {
	opened := make(chan string, 1)
	releaseOpened := make(chan struct{})
	h := newInstance(func(event provider.RuntimeEvent) {
		if event.Type == provider.RuntimeEventRequestOpened {
			opened <- event.RequestID
			<-releaseOpened
		}
	})
	bindTestSession(h, "thread-1", "sess").collector = &promptCollector{threadID: "thread-1", turnID: "turn-1"}
	h.handleACPSessionUpdate(testSessionNotification(t, `{"sessionId":"sess","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool_1","status":"completed"}}`))

	done := make(chan schema.RequestPermissionResponse, 1)
	go func() {
		resp, _ := h.requestPermission(context.Background(), schema.RequestPermissionRequest{SessionID: "sess", ToolCall: schema.ToolCallUpdate{ToolCallID: "tool_1"}, Options: permissionOptions()})
		done <- resp
	}()
	requestID := <-opened
	if err := h.RespondToRequest(context.Background(), provider.RespondToRequestInput{ThreadID: "thread-1", RequestID: requestID, Decision: provider.ApprovalDecisionAccept}); err == nil {
		t.Fatal("RespondToRequest accepted an approval for an already-settled tool")
	}
	close(releaseOpened)
	select {
	case resp := <-done:
		if resp.Outcome.Outcome != schema.RequestPermissionOutcomeOutcomeCancelled {
			t.Fatalf("permission outcome = %#v, want cancelled", resp.Outcome)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("permission stayed pending after its tool had already settled")
	}
}

// Regression (retry-after-decline): within one turn, a NEW tool_call reusing
// a settled tool-call id re-opens the approval cycle, so a fresh
// session/request_permission for that id must reach the client instead of
// being auto-cancelled by the stale settled marker.
func TestPermissionAnswerableAfterToolCallIDReusedInSameTurn(t *testing.T) {
	opened := make(chan string, 2)
	h := newInstance(func(event provider.RuntimeEvent) {
		if event.Type == provider.RuntimeEventRequestOpened {
			opened <- event.RequestID
		}
	})
	bindTestSession(h, "thread-1", "sess").collector = &promptCollector{threadID: "thread-1", turnID: "turn-1"}

	// Tool X runs and settles (declined) within the turn...
	h.handleACPSessionUpdate(testSessionNotification(t, `{"sessionId":"sess","update":{"sessionUpdate":"tool_call","toolCallId":"tool_1","title":"Edit","kind":"edit","status":"pending"}}`))
	h.handleACPSessionUpdate(testSessionNotification(t, `{"sessionId":"sess","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool_1","status":"failed"}}`))
	// ...then the agent retries: a NEW tool_call with the same id.
	h.handleACPSessionUpdate(testSessionNotification(t, `{"sessionId":"sess","update":{"sessionUpdate":"tool_call","toolCallId":"tool_1","title":"Edit","kind":"edit","status":"pending"}}`))

	done := make(chan schema.RequestPermissionResponse, 1)
	go func() {
		resp, _ := h.requestPermission(context.Background(), schema.RequestPermissionRequest{SessionID: "sess", ToolCall: schema.ToolCallUpdate{ToolCallID: "tool_1"}, Options: permissionOptions()})
		done <- resp
	}()
	var requestID string
	select {
	case requestID = <-opened:
	case <-time.After(2 * time.Second):
		t.Fatal("re-opened permission request was never published")
	}
	select {
	case resp := <-done:
		t.Fatalf("re-opened permission auto-resolved as %#v, want it to wait for the client", resp.Outcome)
	case <-time.After(50 * time.Millisecond):
	}
	if err := h.RespondToRequest(context.Background(), provider.RespondToRequestInput{ThreadID: "thread-1", RequestID: requestID, Decision: provider.ApprovalDecisionAccept}); err != nil {
		t.Fatalf("RespondToRequest for re-opened permission: %v", err)
	}
	select {
	case resp := <-done:
		if selectedOption(resp) != "allow" {
			t.Fatalf("permission outcome = %#v, want client-selected allow", resp.Outcome)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("re-opened permission was not resolved by the client answer")
	}
}

// Regression: a duplicate concurrent permission request for the same key
// overwrites the cancel registration; the first request's cleanup must not
// unregister the second's cancel, or an interrupt can no longer resolve it.
func TestDuplicatePermissionRequestKeepsCancelRegistration(t *testing.T) {
	opened := make(chan string, 2)
	h := newInstance(func(event provider.RuntimeEvent) {
		if event.Type == provider.RuntimeEventRequestOpened {
			opened <- event.RequestID
		}
	})
	bindTestSession(h, "thread-1", "sess").collector = &promptCollector{threadID: "thread-1", turnID: "turn-1"}

	firstCtx, cancelFirst := context.WithCancel(context.Background())
	defer cancelFirst()
	firstDone := make(chan struct{})
	go func() {
		_, _ = h.requestPermission(firstCtx, schema.RequestPermissionRequest{SessionID: "sess", ToolCall: schema.ToolCallUpdate{ToolCallID: "tool_1"}, Options: permissionOptions()})
		close(firstDone)
	}()
	select {
	case <-opened:
	case <-time.After(2 * time.Second):
		t.Fatal("first permission request was never published")
	}
	secondDone := make(chan schema.RequestPermissionResponse, 1)
	go func() {
		resp, _ := h.requestPermission(context.Background(), schema.RequestPermissionRequest{SessionID: "sess", ToolCall: schema.ToolCallUpdate{ToolCallID: "tool_1"}, Options: permissionOptions()})
		secondDone <- resp
	}()
	select {
	case <-opened:
	case <-time.After(2 * time.Second):
		t.Fatal("duplicate permission request was never published")
	}

	// First request resolves (agent-side cancel); its cleanup runs.
	cancelFirst()
	select {
	case <-firstDone:
	case <-time.After(2 * time.Second):
		t.Fatal("first permission request did not resolve after its context was cancelled")
	}

	// An interrupt must still find and cancel the second (live) request.
	cancels, matched, _, _ := h.markPromptCancelled("sess", "turn-1")
	if !matched || len(cancels) != 1 {
		t.Fatalf("interrupt found %d pending permission cancels (matched=%v), want the duplicate request still registered", len(cancels), matched)
	}
	for _, cancel := range cancels {
		cancel()
	}
	select {
	case resp := <-secondDone:
		if resp.Outcome.Outcome != schema.RequestPermissionOutcomeOutcomeCancelled {
			t.Fatalf("duplicate permission outcome = %#v, want cancelled by interrupt", resp.Outcome)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("duplicate permission request was orphaned: interrupt could not cancel it")
	}
}

func TestRespondToRequestSelectsExplicitOptionOrDecisionFallback(t *testing.T) {
	opened := make(chan string, 1)
	h := newInstance(func(event provider.RuntimeEvent) {
		if event.Type == provider.RuntimeEventRequestOpened {
			opened <- event.RequestID
		}
	})
	bindTestSession(h, "thread-1", "sess").collector = &promptCollector{threadID: "thread-1", turnID: "turn-1"}
	request := func(toolCallID string, options []schema.PermissionOption) (string, <-chan schema.RequestPermissionResponse) {
		t.Helper()
		done := make(chan schema.RequestPermissionResponse, 1)
		go func() {
			resp, _ := h.requestPermission(context.Background(), schema.RequestPermissionRequest{SessionID: "sess", ToolCall: schema.ToolCallUpdate{ToolCallID: schema.ToolCallId(toolCallID)}, Options: options})
			done <- resp
		}()
		return <-opened, done
	}

	requestID, done := request("tool_1", permissionOptionsWithAllowAlways())
	if err := h.RespondToRequest(context.Background(), provider.RespondToRequestInput{ThreadID: "thread-1", RequestID: requestID, Decision: provider.ApprovalDecisionAccept, OptionID: "no-such-option"}); err == nil {
		t.Fatal("RespondToRequest with unknown optionId err = nil, want rejection while request stays pending")
	}
	// The accept decision alone would map to allow-once; the explicitly
	// selected option must win over the kind-based mapping.
	if err := h.RespondToRequest(context.Background(), provider.RespondToRequestInput{ThreadID: "thread-1", RequestID: requestID, Decision: provider.ApprovalDecisionAccept, OptionID: "allow-always"}); err != nil {
		t.Fatalf("RespondToRequest: %v", err)
	}
	if resp := <-done; selectedOption(resp) != "allow-always" {
		t.Fatalf("permission outcome = %#v, want selected allow-always", resp.Outcome)
	}

	requestID, done = request("tool_2", permissionOptions())
	if err := h.RespondToRequest(context.Background(), provider.RespondToRequestInput{ThreadID: "thread-1", RequestID: requestID, Decision: provider.ApprovalDecisionDecline}); err != nil {
		t.Fatalf("RespondToRequest with decision fallback: %v", err)
	}
	if resp := <-done; selectedOption(resp) != "reject" {
		t.Fatalf("permission outcome = %#v, want decline mapped to reject", resp.Outcome)
	}
}

func TestPermissionRequestAfterTurnCancellationResolvesOnCancelledTurn(t *testing.T) {
	var events []provider.RuntimeEvent
	h := newInstance(func(event provider.RuntimeEvent) { events = append(events, event) })
	bindTestSession(h, "thread-1", "sess").collector = &promptCollector{threadID: "thread-1", turnID: "turn-1"}
	if _, matched, _, _ := h.markPromptCancelled("sess", "turn-1"); !matched {
		t.Fatal("expected active turn-1 collector to be cancelled")
	}

	resp, err := h.requestPermission(context.Background(), schema.RequestPermissionRequest{SessionID: "sess", ToolCall: schema.ToolCallUpdate{ToolCallID: "tool-old"}, Options: permissionOptions()})
	if err != nil {
		t.Fatalf("requestPermission: %v", err)
	}
	if resp.Outcome.Outcome != schema.RequestPermissionOutcomeOutcomeCancelled {
		t.Fatalf("permission outcome = %#v, want cancelled stale request", resp.Outcome)
	}
	if len(events) != 2 || events[0].Type != provider.RuntimeEventRequestOpened || events[1].Type != provider.RuntimeEventRequestResolved {
		t.Fatalf("events = %#v, want ordered opened and resolved events", events)
	}
	for _, event := range events {
		if event.TurnID != "turn-1" {
			t.Fatalf("event = %#v, want cancelled permission associated with turn-1", event)
		}
		if event.ThreadID != "thread-1" {
			t.Fatalf("event = %#v, want thread association preserved", event)
		}
		if event.RequestID == "" || event.RequestID != events[0].RequestID {
			t.Fatalf("event = %#v, want one stable request id across open and resolution", event)
		}
	}
	if !events[1].Payload.Cancelled || events[1].Payload.Decision != provider.ApprovalDecisionCancel {
		t.Fatalf("resolved event = %#v, want cancelled decision", events[1])
	}
}

// promptJoinsCollector decides whether SendTurn steers the live turn or
// starts a fresh one. Cancelled turns, completing turns (turn.completed
// emission underway) and different turn ids must all start a fresh collector.
func TestPromptJoinsCollectorClassification(t *testing.T) {
	cases := []struct {
		name      string
		collector *promptCollector
		turnID    string
		want      bool
	}{
		{"nil collector", nil, "turn-1", false},
		{"live same turn", &promptCollector{turnID: "turn-1"}, "turn-1", true},
		{"live empty turn id", &promptCollector{turnID: "turn-1"}, "", true},
		{"different turn id", &promptCollector{turnID: "turn-1"}, "turn-2", false},
		{"cancelled turn", &promptCollector{turnID: "turn-1", cancelled: true}, "turn-1", false},
		{"completing turn", &promptCollector{turnID: "turn-1", completing: true}, "turn-1", false},
	}
	for _, tc := range cases {
		if got := promptJoinsCollector(tc.collector, tc.turnID); got != tc.want {
			t.Errorf("%s: promptJoinsCollector = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestInfoReturnsDeepCopy(t *testing.T) {
	h := &Instance{info: provider.InstanceInfo{
		Auth:     provider.Auth{Methods: []provider.AuthMethod{{ID: "agent-login"}}},
		Metadata: map[string]json.RawMessage{"raw": json.RawMessage(`{"ok":true}`)},
	}}
	info := h.Info()
	info.Auth.Methods[0].ID = "mutated"
	info.Metadata["raw"][0] = 'x'
	info.Metadata["new"] = json.RawMessage(`true`)

	again := h.Info()
	if again.Auth.Methods[0].ID != "agent-login" || string(again.Metadata["raw"]) != `{"ok":true}` {
		t.Fatalf("info = %#v, want original values unaffected by caller mutation", again)
	}
	if _, ok := again.Metadata["new"]; ok {
		t.Fatalf("metadata contains caller-added key: %#v", again.Metadata)
	}
}

// Regression: OpenInstance can fail between newInstance and a fully wired
// process (connectClient error, initialize error). Close (and the error-path
// cleanup) must be safe on such a partially-built Instance: nil cmd, nil
// stdin/stdout, nil conn.
func TestCloseIsSafeOnPartiallyBuiltInstance(t *testing.T) {
	h := newInstance(nil)
	if err := h.Close(); err != nil {
		t.Fatalf("Close on partially-built instance err = %v, want nil", err)
	}
}

// --- wire-connected handle tests --------------------------------------------

func TestBindSessionRejectsCrossThreadRebinding(t *testing.T) {
	h := newWireTestHandle(t, &fakeWireAgent{})
	if err := h.bindSession("thread-1", "sess"); err != nil {
		t.Fatalf("first bindSession: %v", err)
	}
	if err := h.bindSession("thread-2", "sess"); err == nil {
		t.Fatal("cross-thread bindSession err = nil")
	}
	if got := h.sessionIDForThread("thread-1"); got != "sess" {
		t.Fatalf("original thread binding = %q, want sess", got)
	}
	if got := h.sessionIDForThread("thread-2"); got != "" {
		t.Fatalf("rejected thread binding = %q, want empty", got)
	}
}

func TestStopSessionReturnsCancelFailureAndKeepsBinding(t *testing.T) {
	h := newWireTestHandle(t, &fakeWireAgent{})
	h.bindSession("thread-1", "sess")
	h.ensureSessionStream("sess")
	collector := &promptCollector{threadID: "thread-1", turnID: "turn-1"}
	h.mu.Lock()
	h.sessions["sess"].collector = collector
	h.mu.Unlock()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := h.StopSession(ctx, provider.StopSessionInput{ThreadID: "thread-1"}); err == nil {
		t.Fatal("StopSession with cancelled context err = nil")
	}
	if got := h.sessionIDForThread("thread-1"); got != "sess" {
		t.Fatalf("thread binding after failed cancel = %q, want sess retained for retry", got)
	}
	if collector.cancelled {
		t.Fatal("failed StopSession poisoned the live turn collector")
	}
}

func TestStopSessionClosesNeverUsedSessionWhenSupported(t *testing.T) {
	closed := make(chan string, 1)
	agent := &fakeWireAgent{
		capabilities: map[string]any{"sessionCapabilities": map[string]any{"close": map[string]any{}}},
		onCloseSession: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			closed <- params.SessionID
			a.respond(id, map[string]any{})
		},
	}
	h := newWireTestHandle(t, agent)
	if _, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-draft"}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := h.StopSession(context.Background(), provider.StopSessionInput{ThreadID: "thread-draft"}); err != nil {
		t.Fatalf("StopSession: %v", err)
	}
	select {
	case sessionID := <-closed:
		if sessionID != "sess" {
			t.Fatalf("closed session = %q, want sess", sessionID)
		}
	case <-time.After(time.Second):
		t.Fatal("never-used session did not call session/close")
	}
	if got := h.sessionIDForThread("thread-draft"); got != "" {
		t.Fatalf("thread binding after close = %q, want unbound", got)
	}
}

func TestInterruptTurnCancelFailureLeavesTurnLive(t *testing.T) {
	promptStarted := make(chan struct{})
	promptRelease := make(chan struct{})
	agent := &fakeWireAgent{}
	agent.onPrompt = func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
		close(promptStarted)
		<-promptRelease
		a.sendUpdate(params.SessionID, agentMessageUpdate("msg-1", "still running"))
		a.respond(id, map[string]any{"stopReason": "end_turn"})
	}
	h := newWireTestHandle(t, agent)
	events := make(chan provider.RuntimeEvent, 8)
	h.runtimeEventListener = func(event provider.RuntimeEvent) { events <- event }
	h.bindSession("thread-1", "sess")
	h.ensureSessionStream("sess")

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "work"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	select {
	case <-promptStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("prompt did not start")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := h.InterruptTurn(ctx, provider.InterruptTurnInput{ThreadID: "thread-1", TurnID: "turn-1"}); err == nil {
		t.Fatal("InterruptTurn with cancelled context err = nil")
	}
	close(promptRelease)

	gotDelta := false
	deadline := time.After(2 * time.Second)
	for {
		select {
		case event := <-events:
			if event.Type == provider.RuntimeEventContentDelta && event.Payload.Delta == "still running" {
				gotDelta = true
			}
			if event.Type == provider.RuntimeEventTurnCompleted {
				if !gotDelta || event.Payload.TurnState != provider.RuntimeTurnCompleted || event.Payload.StopReason != "end_turn" {
					t.Fatalf("events after failed interrupt: delta=%v completion=%#v", gotDelta, event)
				}
				return
			}
		case <-deadline:
			t.Fatal("timed out waiting for normally completed turn after failed interrupt")
		}
	}
}

func TestCurrentModeUpdateRefreshesProjectedSessionMode(t *testing.T) {
	agent := &fakeWireAgent{
		onNewSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			a.respond(id, map[string]any{"sessionId": "sess", "modes": map[string]any{"currentModeId": "code", "availableModes": []any{map[string]any{"id": "code", "name": "Code"}, map[string]any{"id": "architect", "name": "Plan"}}}})
		},
	}
	h := newWireTestHandle(t, agent)
	if _, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	events := make(chan provider.RuntimeEvent, 1)
	h.runtimeEventListener = func(event provider.RuntimeEvent) {
		if event.Type == provider.RuntimeEventConfigOptionsUpdated {
			events <- event
		}
	}
	agent.sendUpdate("sess", map[string]any{"sessionUpdate": "current_mode_update", "currentModeId": "architect"})
	select {
	case event := <-events:
		if len(event.Payload.ConfigOptions) != 1 || event.Payload.ConfigOptions[0].CurrentValue != "architect" || len(event.Payload.ConfigOptions[0].Choices) != 2 || event.Payload.ConfigOptions[0].Choices[0].Value != "code" || event.Payload.ConfigOptions[0].Choices[1].Value != "architect" {
			t.Fatalf("config options event = %#v, want architect current mode", event)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for current mode update")
	}
}

func TestLegacySessionModeUsesConfigOptionPath(t *testing.T) {
	modeCalls := make(chan wireSessionParams, 1)
	agent := &fakeWireAgent{
		onNewSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			a.respond(id, map[string]any{"sessionId": "sess", "modes": map[string]any{"currentModeId": "code", "availableModes": []any{map[string]any{"id": "code", "name": "Code"}, map[string]any{"id": "architect", "name": "Plan"}}}})
		},
		onSetMode: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			modeCalls <- params
			a.respond(id, map[string]any{})
		},
	}
	h := newWireTestHandle(t, agent)
	if _, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := h.SetConfigOption(context.Background(), provider.SetConfigOptionInput{ThreadID: "thread-1", OptionID: acpSessionModeOptionID, Value: "architect"}); err != nil {
		t.Fatalf("SetConfigOption: %v", err)
	}
	select {
	case call := <-modeCalls:
		if call.ModeID != "architect" {
			t.Fatalf("session/set_mode modeId = %q, want architect", call.ModeID)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("session/set_mode was not called")
	}
}

func TestStartSessionRestoresLegacyModeConfigSelection(t *testing.T) {
	modeCalls := make(chan wireSessionParams, 1)
	agent := &fakeWireAgent{
		onNewSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			a.respond(id, map[string]any{"sessionId": "sess", "modes": map[string]any{"currentModeId": "code", "availableModes": []any{map[string]any{"id": "code", "name": "Code"}, map[string]any{"id": "architect", "name": "Plan"}}}})
		},
		onSetMode: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			modeCalls <- params
			a.respond(id, map[string]any{})
		},
	}
	h := newWireTestHandle(t, agent)
	result, err := h.StartSession(context.Background(), provider.StartSessionInput{
		ThreadID: "thread-1",
		ConfigSelections: []provider.ConfigOptionSelection{{
			OptionID: acpSessionModeOptionID,
			Value:    "architect",
			Category: provider.ConfigOptionCategoryMode,
		}},
	})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if len(result.Session.ConfigOptions) != 1 || result.Session.ConfigOptions[0].CurrentValue != "architect" {
		t.Fatalf("restored session config options = %#v, want architect current mode", result.Session.ConfigOptions)
	}
	select {
	case call := <-modeCalls:
		if call.ModeID != "architect" {
			t.Fatalf("restored mode = %q, want architect", call.ModeID)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("restored mode did not call session/set_mode")
	}
}

func TestStartSessionAppliesModelSelectionConfigOption(t *testing.T) {
	recorder := &callRecorder{}
	agent := &fakeWireAgent{
		onNewSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			a.respond(id, map[string]any{"sessionId": "sess", "configOptions": wireModelConfigOptions("model-a")})
		},
		onSetConfigOption: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			recorder.recordConfig(params)
			a.respond(id, map[string]any{"configOptions": wireModelConfigOptions(params.stringValue())})
		},
	}
	h := newWireTestHandle(t, agent)

	result, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1", ModelSelection: &provider.ModelSelection{Model: "model-b"}})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	configCalls := recorder.configCalls()
	if len(configCalls) != 1 || configCalls[0].ConfigID != "model" || configCalls[0].Value != "model-b" {
		t.Fatalf("set_config_option calls = %#v, want model=model-b", configCalls)
	}
	if len(result.Session.ConfigOptions) != 1 || result.Session.ConfigOptions[0].CurrentValue != "model-b" {
		t.Fatalf("session config options = %#v, want current model-b", result.Session.ConfigOptions)
	}
}

func TestStartSessionWarnsWhenModelPreferenceCannotBeApplied(t *testing.T) {
	agent := &fakeWireAgent{
		onNewSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			a.respond(id, map[string]any{"sessionId": "sess", "configOptions": wireModeConfigOptions("code")})
		},
	}
	h := newWireTestHandle(t, agent)
	recorder := &eventRecorder{}
	h.runtimeEventListener = recorder.listener

	if _, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1", ModelSelection: &provider.ModelSelection{Model: "model-b"}}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if got := h.sessionIDForThread("thread-1"); got != "sess" {
		t.Fatalf("thread session = %q, want sess", got)
	}
	events := recorder.snapshot()
	if len(events) != 1 || events[0].Type != provider.RuntimeEventRuntimeWarning || !strings.Contains(events[0].Payload.Message, "model-b") {
		t.Fatalf("events = %#v, want model preference warning", events)
	}
}

// Regression: StartSession runs before EVERY prompt with the thread's stored
// model preference. The in-process reuse branch used to hard-fail when the
// preference no longer matched a config choice, bricking the thread (every
// turn failed with the same error) while the new/load/resume paths already
// downgraded the same condition to a runtime warning.
func TestStartSessionReuseWarnsWhenModelPreferenceCannotBeApplied(t *testing.T) {
	agent := &fakeWireAgent{
		onNewSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			a.respond(id, map[string]any{"sessionId": "sess", "configOptions": wireModeConfigOptions("code")})
		},
	}
	h := newWireTestHandle(t, agent)

	if _, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("initial StartSession: %v", err)
	}
	recorder := &eventRecorder{}
	h.runtimeEventListener = recorder.listener

	result, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1", ModelSelection: &provider.ModelSelection{Model: "model-b"}})
	if err != nil {
		t.Fatalf("reused StartSession with stale model preference err = %v, want warning instead of failure", err)
	}
	if result.Session.ProviderSessionID != "sess" || h.sessionIDForThread("thread-1") != "sess" {
		t.Fatalf("reused session = %#v, want existing sess binding preserved", result.Session)
	}
	events := recorder.snapshot()
	if len(events) != 1 || events[0].Type != provider.RuntimeEventRuntimeWarning || !strings.Contains(events[0].Payload.Message, "model-b") {
		t.Fatalf("events = %#v, want one model preference warning", events)
	}
}

func TestStartSessionPreservesExplicitEmptyConfigOptions(t *testing.T) {
	agent := &fakeWireAgent{
		onNewSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			a.respond(id, map[string]any{"sessionId": "sess", "configOptions": []any{}})
		},
	}
	h := newWireTestHandle(t, agent)

	result, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1"})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if result.Session.ConfigOptions == nil || len(result.Session.ConfigOptions) != 0 {
		t.Fatalf("session config options = %#v, want explicit empty list", result.Session.ConfigOptions)
	}
}

func TestSessionManagementRejectsBoundSession(t *testing.T) {
	h := newWireTestHandle(t, &fakeWireAgent{capabilities: map[string]any{"sessionCapabilities": map[string]any{"delete": map[string]any{}, "close": map[string]any{}}}})
	if _, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := h.DeleteSession(context.Background(), "sess"); err == nil || !strings.Contains(err.Error(), "bound to thread") {
		t.Fatalf("DeleteSession bound session err = %v, want rejection", err)
	}
	if err := h.CloseSession(context.Background(), "sess"); err == nil || !strings.Contains(err.Error(), "bound to thread") {
		t.Fatalf("CloseSession bound session err = %v, want rejection", err)
	}
	if got := h.sessionIDForThread("thread-1"); got != "sess" {
		t.Fatalf("thread binding after rejected maintenance = %q, want sess", got)
	}
}

func TestListSessionsFollowsPagination(t *testing.T) {
	var mu sync.Mutex
	var cursors []string
	agent := &fakeWireAgent{
		capabilities: map[string]any{"sessionCapabilities": map[string]any{"list": map[string]any{}}},
		onListSessions: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			mu.Lock()
			cursors = append(cursors, params.Cursor)
			mu.Unlock()
			if params.Cursor == "" {
				a.respond(id, map[string]any{"sessions": []any{map[string]any{"sessionId": "one", "cwd": "/tmp"}}, "nextCursor": "page-2"})
				return
			}
			a.respond(id, map[string]any{"sessions": []any{map[string]any{"sessionId": "two", "cwd": "/tmp"}}})
		},
	}
	h := newWireTestHandle(t, agent)
	sessions, err := h.ListSessions(context.Background(), "/tmp")
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(sessions) != 2 || sessions[0].SessionID != "one" || sessions[1].SessionID != "two" {
		t.Fatalf("sessions = %#v, want both pages", sessions)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(cursors) != 2 || cursors[0] != "" || cursors[1] != "page-2" {
		t.Fatalf("cursors = %#v, want empty then page-2", cursors)
	}
}

func TestStartSessionPropagatesNonRecoverableLoadError(t *testing.T) {
	recorder := &callRecorder{}
	agent := &fakeWireAgent{
		capabilities: map[string]any{"loadSession": true},
		onLoadSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			a.respondError(id, -32000, "Authentication required")
		},
		onNewSession: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			recorder.recordConfig(params) // reuse recorder as a call counter
			a.respond(id, map[string]any{"sessionId": "fresh"})
		},
	}
	h := newWireTestHandle(t, agent)

	_, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1", Cwd: "/tmp", ResumeCursor: marshalRaw(map[string]string{"sessionId": "old"})})
	if err == nil {
		t.Fatal("StartSession err = nil, want load error")
	}
	var requestErr *provider.RequestError
	if !errors.As(err, &requestErr) || requestErr.Code != -32000 || requestErr.Message != "Authentication required" {
		t.Fatalf("StartSession err = %#v, want preserved -32000 Authentication required request error", err)
	}
	if calls := recorder.configCalls(); len(calls) != 0 {
		t.Fatalf("session/new calls = %d, want 0 for non-recoverable load error", len(calls))
	}
	if got := h.sessionIDForThread("thread-1"); got != "" {
		t.Fatalf("thread remains bound to %q after failed load", got)
	}
}

func TestStartSessionFallsBackToNewSessionWhenLoadSessionResourceNotFound(t *testing.T) {
	loads := &callRecorder{}
	news := &callRecorder{}
	agent := &fakeWireAgent{
		capabilities: map[string]any{"loadSession": true},
		onLoadSession: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			loads.recordConfig(params)
			a.respondError(id, -32002, "Resource not found")
		},
		onNewSession: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			news.recordConfig(params)
			a.respond(id, map[string]any{"sessionId": "fresh"})
		},
	}
	h := newWireTestHandle(t, agent)

	result, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1", Cwd: "/tmp", ResumeCursor: marshalRaw(map[string]string{"sessionId": "old"})})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if len(loads.configCalls()) != 1 || len(news.configCalls()) != 1 {
		t.Fatalf("load/new calls = %d/%d, want 1/1", len(loads.configCalls()), len(news.configCalls()))
	}
	if got := h.sessionIDForThread("thread-1"); got != "fresh" {
		t.Fatalf("thread bound to %q, want fresh", got)
	}
	if got := resumeSessionID(result.Session.ResumeCursor); got != "fresh" {
		t.Fatalf("resume cursor session = %q, want fresh", got)
	}
}

func TestLoadSessionDropsReplayedUpdates(t *testing.T) {
	agent := &fakeWireAgent{
		capabilities: map[string]any{"loadSession": true},
		onLoadSession: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			a.sendUpdate("old", agentMessageUpdate("msg-1", "hello"))
			a.respond(id, map[string]any{})
		},
	}
	h := newWireTestHandle(t, agent)
	recorder := &eventRecorder{}
	h.runtimeEventListener = recorder.listener

	if _, err := h.StartSession(context.Background(), provider.StartSessionInput{
		ThreadID:     "thread-1",
		ResumeCursor: marshalRaw(map[string]string{"sessionId": "old"}),
	}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if events := recorder.snapshot(); len(events) != 0 {
		t.Fatalf("events = %#v, want replay suppressed", events)
	}
}

func TestReplayHistoryLoadsAndReturnsReplayedUpdates(t *testing.T) {
	loads := &callRecorder{}
	resumes := &callRecorder{}
	agent := &fakeWireAgent{
		capabilities: map[string]any{"loadSession": true, "sessionCapabilities": map[string]any{"resume": map[string]any{}}},
		onLoadSession: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			loads.recordConfig(params)
			a.sendUpdate("old", agentMessageUpdate("msg-1", "restored"))
			a.respond(id, map[string]any{})
		},
		onResumeSession: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			resumes.recordConfig(params)
			a.respond(id, map[string]any{})
		},
	}
	h := newWireTestHandle(t, agent)
	recorder := &eventRecorder{}
	h.runtimeEventListener = recorder.listener

	result, err := h.StartSession(context.Background(), provider.StartSessionInput{
		ThreadID:      "thread-1",
		ResumeCursor:  marshalRaw(map[string]string{"sessionId": "old"}),
		ReplayHistory: true,
	})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if len(loads.configCalls()) != 1 || len(resumes.configCalls()) != 0 {
		t.Fatalf("load/resume calls = %d/%d, want 1/0", len(loads.configCalls()), len(resumes.configCalls()))
	}
	events := result.Replay
	if len(events) != 1 || events[0].ThreadID != "thread-1" || events[0].Payload.Delta != "restored" {
		t.Fatalf("replay = %#v, want history routed to thread-1", events)
	}
	if live := recorder.snapshot(); len(live) != 0 {
		t.Fatalf("live events = %#v, want replay returned atomically", live)
	}
}

func TestReplayHistoryDiscardsFailedLoadBeforeRetry(t *testing.T) {
	var h *Instance
	var attemptsMu sync.Mutex
	attempts := 0
	agent := &fakeWireAgent{
		capabilities: map[string]any{"loadSession": true},
		onLoadSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			attemptsMu.Lock()
			attempts++
			attempt := attempts
			attemptsMu.Unlock()

			a.sendUpdate("old", agentMessageUpdate("msg-1", "first"))
			a.sendUpdate("old", agentMessageUpdate("msg-2", "second"))
			if attempt == 1 {
				deadline := time.Now().Add(2 * time.Second)
				buffered := false
				for time.Now().Before(deadline) {
					h.mu.Lock()
					session := h.sessions["old"]
					buffered = session != nil && len(session.replayEvents) == 2
					h.mu.Unlock()
					if buffered {
						break
					}
					time.Sleep(time.Millisecond)
				}
				if !buffered {
					a.t.Error("timed out waiting for replay updates to be buffered")
				}
				a.respondError(id, -32000, "load failed")
				return
			}
			a.respond(id, map[string]any{})
		},
	}
	h = newWireTestHandle(t, agent)
	recorder := &eventRecorder{}
	h.runtimeEventListener = recorder.listener
	input := provider.StartSessionInput{
		ThreadID:      "thread-1",
		ResumeCursor:  marshalRaw(map[string]string{"sessionId": "old"}),
		ReplayHistory: true,
	}

	if _, err := h.StartSession(context.Background(), input); err == nil {
		t.Fatal("first StartSession err = nil, want failed load")
	}
	if events := recorder.snapshot(); len(events) != 0 {
		t.Fatalf("events after failed load = %#v, want replay discarded", events)
	}
	result, err := h.StartSession(context.Background(), input)
	if err != nil {
		t.Fatalf("retry StartSession: %v", err)
	}
	events := result.Replay
	if len(events) != 2 || events[0].Payload.Delta != "first" || events[1].Payload.Delta != "second" {
		t.Fatalf("replay after retry = %#v, want complete history in order", events)
	}
}

func TestReplayHistoryReportsUnavailable(t *testing.T) {
	tests := []struct {
		name         string
		capabilities map[string]any
		wantResume   bool
		wantSession  string
	}{
		{name: "resume without display replay", capabilities: map[string]any{"sessionCapabilities": map[string]any{"resume": map[string]any{}}}, wantResume: true, wantSession: "old"},
		{name: "fresh session without recovery", capabilities: map[string]any{}, wantSession: "sess"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resumes := &callRecorder{}
			agent := &fakeWireAgent{
				capabilities: tt.capabilities,
				onResumeSession: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
					resumes.recordConfig(params)
					a.respond(id, map[string]any{})
				},
			}
			h := newWireTestHandle(t, agent)
			result, err := h.StartSession(context.Background(), provider.StartSessionInput{
				ThreadID:      "thread-1",
				ResumeCursor:  marshalRaw(map[string]string{"sessionId": "old"}),
				ReplayHistory: true,
			})
			if err != nil {
				t.Fatalf("StartSession: %v", err)
			}
			if got := len(resumes.configCalls()) > 0; got != tt.wantResume {
				t.Fatalf("resume called = %v, want %v", got, tt.wantResume)
			}
			if !result.HistoryUnavailable || len(result.Replay) != 0 {
				t.Fatalf("result = %#v, want unavailable history without replay", result)
			}
			if result.Session.ProviderSessionID != tt.wantSession || h.sessionIDForThread("thread-1") != tt.wantSession {
				t.Fatalf("result session = %#v, bound = %q, want %q", result.Session, h.sessionIDForThread("thread-1"), tt.wantSession)
			}
		})
	}
}

func TestStartSessionPrefersResumeOverLoad(t *testing.T) {
	loads := &callRecorder{}
	resumes := &callRecorder{}
	agent := &fakeWireAgent{
		capabilities: map[string]any{"loadSession": true, "sessionCapabilities": map[string]any{"resume": map[string]any{}}},
		onLoadSession: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			loads.recordConfig(params)
			a.respond(id, map[string]any{})
		},
		onResumeSession: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			resumes.recordConfig(params)
			a.respond(id, map[string]any{"configOptions": wireModelConfigOptions("model-a")})
		},
	}
	h := newWireTestHandle(t, agent)

	result, err := h.StartSession(context.Background(), provider.StartSessionInput{
		ThreadID:     "thread-1",
		Cwd:          "/tmp",
		ResumeCursor: marshalRaw(map[string]string{"sessionId": "old"}),
	})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if len(resumes.configCalls()) != 1 || len(loads.configCalls()) != 0 {
		t.Fatalf("resume/load calls = %d/%d, want 1/0", len(resumes.configCalls()), len(loads.configCalls()))
	}
	if got := h.sessionIDForThread("thread-1"); got != "old" {
		t.Fatalf("thread bound to %q, want old", got)
	}
	if got := resumeSessionID(result.Session.ResumeCursor); got != "old" {
		t.Fatalf("resume cursor session = %q, want old", got)
	}
}

func TestResumeSessionRoutesUpdatesEmittedBeforeResponse(t *testing.T) {
	agent := &fakeWireAgent{
		capabilities: map[string]any{"sessionCapabilities": map[string]any{"resume": map[string]any{}}},
		onResumeSession: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			a.sendUpdate("old", agentMessageUpdate("msg-1", "resumed"))
			a.respond(id, map[string]any{"configOptions": wireModelConfigOptions("model-a")})
		},
	}
	h := newWireTestHandle(t, agent)
	recorder := &eventRecorder{}
	h.runtimeEventListener = recorder.listener

	if _, err := h.StartSession(context.Background(), provider.StartSessionInput{
		ThreadID:     "thread-1",
		ResumeCursor: marshalRaw(map[string]string{"sessionId": "old"}),
	}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	events := recorder.snapshot()
	if len(events) != 1 || events[0].ThreadID != "thread-1" || events[0].Payload.Delta != "resumed" {
		t.Fatalf("events = %#v, want resume update routed to thread-1", events)
	}
}

// Wire-level regression for the settled-tool tombstone: agents resend a
// terminal tool_call_update carrying late rawOutput AFTER the tool already
// settled. That trailing update must reach the listener as a well-formed
// ItemUpdated (itemType/status enriched from the tombstone) so ingestion can
// merge it downstream instead of silently dropping an empty-ItemType event.
func TestTrailingToolCallUpdateAfterSettleEmitsWellFormedEvent(t *testing.T) {
	agent := &fakeWireAgent{}
	agent.onPrompt = func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
		a.sendUpdate(params.SessionID, map[string]any{"sessionUpdate": "tool_call", "toolCallId": "tool-1", "title": "Run tests", "kind": "execute", "status": "pending"})
		a.sendUpdate(params.SessionID, map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": "tool-1", "status": "completed"})
		// Trailing terminal update with the late output attached.
		a.sendUpdate(params.SessionID, map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": "tool-1", "rawOutput": map[string]any{"stdout": "late output"}})
		a.respond(id, map[string]any{"stopReason": "end_turn"})
	}
	h := newWireTestHandle(t, agent)
	recorder := &eventRecorder{}
	turnDone := make(chan struct{}, 1)
	h.runtimeEventListener = func(event provider.RuntimeEvent) {
		recorder.listener(event)
		if event.Type == provider.RuntimeEventTurnCompleted {
			turnDone <- struct{}{}
		}
	}
	h.bindSession("thread-1", "sess")
	h.ensureSessionStream("sess")

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "run"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	select {
	case <-turnDone:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for turn completion")
	}

	var itemEvents []provider.RuntimeEvent
	for _, event := range recorder.snapshot() {
		if event.Type == provider.RuntimeEventItemStarted || event.Type == provider.RuntimeEventItemUpdated {
			itemEvents = append(itemEvents, event)
		}
	}
	if len(itemEvents) != 3 {
		t.Fatalf("item events = %#v, want start, terminal update, trailing update", itemEvents)
	}
	trailing := itemEvents[2]
	if trailing.Type != provider.RuntimeEventItemUpdated || trailing.ThreadID != "thread-1" || trailing.TurnID != "turn-1" {
		t.Fatalf("trailing event = %#v, want item update on thread-1 turn-1", trailing)
	}
	if trailing.Payload.ItemType != provider.ItemKindCommandExecution || trailing.Payload.ItemStatus != provider.ItemStatusCompleted {
		t.Fatalf("trailing event payload = %#v, want tombstone-enriched command_execution/completed", trailing.Payload)
	}
	if !strings.Contains(string(trailing.Payload.Data), "late output") {
		t.Fatalf("trailing event data = %s, want the late rawOutput carried through", trailing.Payload.Data)
	}
}

func TestSendTurnWaitsForCancelledPromptBeforeFollowUpSoNewUpdatesAreDelivered(t *testing.T) {
	firstPromptStarted := make(chan struct{})
	firstPromptRelease := make(chan struct{})
	secondPromptStarted := make(chan struct{})
	var promptMu sync.Mutex
	promptCalls := 0
	agent := &fakeWireAgent{}
	agent.onPrompt = func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
		promptMu.Lock()
		promptCalls++
		call := promptCalls
		promptMu.Unlock()
		switch call {
		case 1:
			close(firstPromptStarted)
			<-firstPromptRelease
			a.respond(id, map[string]any{"stopReason": "cancelled"})
		case 2:
			close(secondPromptStarted)
			a.sendUpdate(params.SessionID, agentMessageUpdate("msg-new", "hello"))
			a.respond(id, map[string]any{"stopReason": "end_turn"})
		default:
			a.respond(id, map[string]any{"stopReason": "end_turn"})
		}
	}
	h := newWireTestHandle(t, agent)
	eventCh := make(chan provider.RuntimeEvent, 4)
	h.runtimeEventListener = func(event provider.RuntimeEvent) {
		if event.Type == provider.RuntimeEventContentDelta {
			eventCh <- event
		}
	}
	h.bindSession("thread-1", "sess")
	h.ensureSessionStream("sess")

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "first"}); err != nil {
		t.Fatalf("first SendTurn: %v", err)
	}
	select {
	case <-firstPromptStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("first prompt did not start")
	}
	if err := h.InterruptTurn(context.Background(), provider.InterruptTurnInput{ThreadID: "thread-1", TurnID: "turn-1"}); err != nil {
		t.Fatalf("InterruptTurn: %v", err)
	}

	followUpDone := make(chan error, 1)
	go func() {
		followUpDone <- h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-2", Input: "second"})
	}()
	select {
	case <-secondPromptStarted:
		t.Fatal("follow-up prompt started before cancelled prompt drained")
	case <-time.After(50 * time.Millisecond):
	}
	agent.sendUpdate("sess", agentMessageUpdate("msg-old", "late"))
	select {
	case event := <-eventCh:
		t.Fatalf("event while old prompt drains = %#v, want stale update suppressed", event)
	case <-time.After(50 * time.Millisecond):
	}

	close(firstPromptRelease)
	select {
	case <-secondPromptStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("follow-up prompt did not start after cancelled prompt drained")
	}
	if err := <-followUpDone; err != nil {
		t.Fatalf("follow-up SendTurn: %v", err)
	}
	select {
	case event := <-eventCh:
		if event.TurnID != "turn-2" || event.Payload.Delta != "hello" {
			t.Fatalf("event = %#v, want delivered turn-2 assistant delta", event)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for follow-up assistant delta")
	}
}

// Regression for codex-acp (Zed's own client cancels the running prompt before
// every send): an agent may accept an overlapping session/prompt's text but
// never answer the second RPC, wedging the turn forever. A steering prompt must
// therefore cancel the in-flight prompt, wait for it to settle, then dispatch —
// and the turn must still complete normally from the steering prompt.
func TestSteeringPromptCancelsInFlightPromptAndCompletesTurn(t *testing.T) {
	firstPromptStarted := make(chan struct{})
	firstPromptRelease := make(chan struct{})
	secondPromptStarted := make(chan struct{})
	cancelCalls := make(chan struct{}, 1)
	var promptMu sync.Mutex
	promptCalls := 0
	agent := &fakeWireAgent{}
	agent.onPrompt = func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
		promptMu.Lock()
		promptCalls++
		call := promptCalls
		promptMu.Unlock()
		if call == 1 {
			close(firstPromptStarted)
			<-firstPromptRelease
			a.respond(id, map[string]any{"stopReason": "cancelled"})
			return
		}
		close(secondPromptStarted)
		a.respond(id, map[string]any{"stopReason": "end_turn"})
	}
	agent.onCancel = func(a *fakeWireAgent, params wireSessionParams) {
		select {
		case cancelCalls <- struct{}{}:
		default:
		}
	}
	h := newWireTestHandle(t, agent)
	turnEvents := make(chan provider.RuntimeEvent, 8)
	h.runtimeEventListener = func(event provider.RuntimeEvent) {
		if event.Type == provider.RuntimeEventTurnCompleted {
			turnEvents <- event
		}
	}
	h.bindSession("thread-1", "sess")
	h.ensureSessionStream("sess")

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "first"}); err != nil {
		t.Fatalf("first SendTurn: %v", err)
	}
	select {
	case <-firstPromptStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("first prompt did not start")
	}

	// Steer the SAME turn while the first prompt is still in flight.
	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "steer"}); err != nil {
		t.Fatalf("steering SendTurn: %v", err)
	}
	select {
	case <-cancelCalls:
	case <-time.After(2 * time.Second):
		t.Fatal("steering prompt did not send session/cancel for the in-flight prompt")
	}
	select {
	case <-secondPromptStarted:
		t.Fatal("steering prompt dispatched while first prompt still in flight")
	case <-time.After(50 * time.Millisecond):
	}

	close(firstPromptRelease)
	select {
	case <-secondPromptStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("steering prompt did not dispatch after cancelled prompt settled")
	}
	select {
	case event := <-turnEvents:
		if event.TurnID != "turn-1" || event.Payload.TurnState != provider.RuntimeTurnCompleted {
			t.Fatalf("turn completion = %#v, want turn-1 completed from steering prompt", event)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for steered turn completion")
	}
	waitForNoActiveCollector(t, h, "sess")
}

func TestSteeringPreservesEveryQueuedPrompt(t *testing.T) {
	firstPromptStarted := make(chan struct{})
	firstPromptRelease := make(chan struct{})
	allPromptsDone := make(chan struct{})
	var promptMu sync.Mutex
	var prompts []string
	agent := &fakeWireAgent{}
	agent.onPrompt = func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
		promptMu.Lock()
		prompts = append(prompts, params.Prompt[0].Text)
		call := len(prompts)
		promptMu.Unlock()
		if call == 1 {
			close(firstPromptStarted)
			<-firstPromptRelease
			a.respond(id, map[string]any{"stopReason": "cancelled"})
			return
		}
		a.respond(id, map[string]any{"stopReason": "end_turn"})
		if call == 3 {
			close(allPromptsDone)
		}
	}
	h := newWireTestHandle(t, agent)
	h.bindSession("thread-1", "sess")
	h.ensureSessionStream("sess")

	for _, input := range []string{"first", "steer one", "steer two"} {
		if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: input}); err != nil {
			t.Fatalf("SendTurn(%q): %v", input, err)
		}
		if input == "first" {
			select {
			case <-firstPromptStarted:
			case <-time.After(2 * time.Second):
				t.Fatal("first prompt did not start")
			}
		}
	}
	close(firstPromptRelease)
	select {
	case <-allPromptsDone:
	case <-time.After(2 * time.Second):
		t.Fatal("queued steering prompts did not all dispatch")
	}
	promptMu.Lock()
	defer promptMu.Unlock()
	want := []string{"first", "steer one", "steer two"}
	if fmt.Sprint(prompts) != fmt.Sprint(want) {
		t.Fatalf("prompt order = %#v, want %#v", prompts, want)
	}
}

func TestSteeringPromptSettlesAbandonedToolItems(t *testing.T) {
	firstPromptStarted := make(chan struct{})
	firstPromptRelease := make(chan struct{})
	secondPromptStarted := make(chan struct{})
	cancelCalls := make(chan struct{}, 1)
	var promptMu sync.Mutex
	promptCalls := 0
	agent := &fakeWireAgent{}
	agent.onPrompt = func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
		promptMu.Lock()
		promptCalls++
		call := promptCalls
		promptMu.Unlock()
		if call == 1 {
			a.sendUpdate(params.SessionID, map[string]any{"sessionUpdate": "tool_call", "toolCallId": "tool-1", "title": "Run tests", "kind": "execute", "status": "pending"})
			close(firstPromptStarted)
			<-firstPromptRelease
			a.respond(id, map[string]any{"stopReason": "cancelled"})
			return
		}
		close(secondPromptStarted)
		a.respond(id, map[string]any{"stopReason": "end_turn"})
	}
	agent.onCancel = func(a *fakeWireAgent, params wireSessionParams) {
		select {
		case cancelCalls <- struct{}{}:
		default:
		}
	}
	h := newWireTestHandle(t, agent)
	recorder := &eventRecorder{}
	h.runtimeEventListener = recorder.listener
	h.bindSession("thread-1", "sess")
	h.ensureSessionStream("sess")

	waitForEvent := func(name string, pred func(provider.RuntimeEvent) bool) provider.RuntimeEvent {
		t.Helper()
		deadline := time.After(2 * time.Second)
		for {
			for _, event := range recorder.snapshot() {
				if pred(event) {
					return event
				}
			}
			select {
			case <-deadline:
				t.Fatalf("timed out waiting for %s; events = %#v", name, recorder.snapshot())
			case <-time.After(10 * time.Millisecond):
			}
		}
	}

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "first"}); err != nil {
		t.Fatalf("first SendTurn: %v", err)
	}
	select {
	case <-firstPromptStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("first prompt did not start")
	}
	started := waitForEvent("tool start", func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventItemStarted && event.Payload.ItemStatus == provider.ItemStatusInProgress
	})
	if started.Payload.ItemType != provider.ItemKindCommandExecution || started.ThreadID != "thread-1" || started.TurnID != "turn-1" {
		t.Fatalf("tool start = %#v, want command_execution on turn-1", started)
	}

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "steer"}); err != nil {
		t.Fatalf("steering SendTurn: %v", err)
	}
	select {
	case <-cancelCalls:
	case <-time.After(2 * time.Second):
		t.Fatal("steering prompt did not send session/cancel")
	}
	close(firstPromptRelease)
	select {
	case <-secondPromptStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("steering prompt did not dispatch after cancelled prompt settled")
	}

	settled := waitForEvent("abandoned tool settlement", func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventItemUpdated && event.ItemID == started.ItemID && event.Payload.ItemStatus == provider.ItemStatusInterrupted
	})
	if settled.Payload.ItemType != provider.ItemKindCommandExecution || settled.ThreadID != "thread-1" || settled.TurnID != "turn-1" {
		t.Fatalf("abandoned tool settlement = %#v, want interrupted command_execution on same turn", settled)
	}
	h.mu.Lock()
	openToolStates := 0
	if session := h.sessions["sess"]; session != nil {
		for _, state := range session.toolStates {
			if !state.settled {
				openToolStates++
			}
		}
	}
	h.mu.Unlock()
	if openToolStates != 0 {
		t.Fatalf("open tool reconciliation entries after abandoned settlement = %d, want 0 (settled tombstones only)", openToolStates)
	}
	completed := waitForEvent("steered turn completion", func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventTurnCompleted
	})
	if completed.Payload.TurnState != provider.RuntimeTurnCompleted {
		t.Fatalf("turn completion = %#v, want completed steering turn", completed)
	}
	waitForNoActiveCollector(t, h, "sess")
}

// Regression (client-visible flicker): a steer can land in the window where
// the previous turn's last prompt settled but its turn.completed emission is
// still in progress. The engine still sees the turn as running (turn.completed
// is travelling hub->ingestion->engine), so the steer reuses the active turn id.
// The steer must not emit its turn.started until the old turn's completion has
// been emitted — before the fix the two emissions raced across goroutines.
func TestSteerDuringTurnCompletionChainsStartAfterCompletion(t *testing.T) {
	agent := &fakeWireAgent{} // every prompt resolves immediately with end_turn
	h := newWireTestHandle(t, agent)

	type lifecycleEvent struct {
		kind   provider.RuntimeEventType
		turnID string
	}
	var mu sync.Mutex
	var lifecycle []lifecycleEvent
	snapshot := func() []lifecycleEvent {
		mu.Lock()
		defer mu.Unlock()
		return append([]lifecycleEvent(nil), lifecycle...)
	}
	completing := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	h.runtimeEventListener = func(event provider.RuntimeEvent) {
		switch event.Type {
		case provider.RuntimeEventTurnStarted, provider.RuntimeEventTurnCompleted:
			mu.Lock()
			lifecycle = append(lifecycle, lifecycleEvent{kind: event.Type, turnID: event.TurnID})
			mu.Unlock()
			if event.Type == provider.RuntimeEventTurnCompleted {
				once.Do(func() {
					close(completing)
					<-release // hold the consumer inside the first completion emission
				})
			}
		}
	}
	h.bindSession("thread-1", "sess")
	h.ensureSessionStream("sess")

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "first"}); err != nil {
		t.Fatalf("first SendTurn: %v", err)
	}
	select {
	case <-completing:
	case <-time.After(2 * time.Second):
		t.Fatal("first turn never reached its completion emission")
	}

	// Steer lands while turn-1's completion emission is still in progress.
	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "steer"}); err != nil {
		t.Fatalf("steering SendTurn: %v", err)
	}
	time.Sleep(50 * time.Millisecond)
	if got := snapshot(); len(got) != 2 {
		t.Fatalf("lifecycle during completion window = %#v, want the steer's turn.started deferred until the completion is emitted", got)
	}

	close(release)
	deadline := time.After(2 * time.Second)
	for {
		got := snapshot()
		if len(got) >= 4 {
			want := []lifecycleEvent{
				{provider.RuntimeEventTurnStarted, "turn-1"},
				{provider.RuntimeEventTurnCompleted, "turn-1"},
				{provider.RuntimeEventTurnStarted, "turn-1"},
				{provider.RuntimeEventTurnCompleted, "turn-1"},
			}
			for i := range want {
				if got[i] != want[i] {
					t.Fatalf("lifecycle = %#v, want started/completed strictly alternating", got)
				}
			}
			return
		}
		select {
		case <-deadline:
			t.Fatalf("timed out waiting for steered turn lifecycle; got %#v", snapshot())
		case <-time.After(10 * time.Millisecond):
		}
	}
}

// Regression (audited leak): an interrupted turn's tool reconciliation
// entries used to live until session unbind — post-cancel updates are
// dropped, so their terminal statuses never arrive. They must be cleared when
// the turn ends.
func TestInterruptedTurnToolStatesClearedAtTurnEnd(t *testing.T) {
	promptRelease := make(chan struct{})
	agent := &fakeWireAgent{}
	agent.onPrompt = func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
		a.sendUpdate(params.SessionID, map[string]any{"sessionUpdate": "tool_call", "toolCallId": "tool-1", "title": "Run tests", "kind": "execute", "status": "pending"})
		<-promptRelease
		a.respond(id, map[string]any{"stopReason": "cancelled"})
	}
	agent.onCancel = func(a *fakeWireAgent, _ wireSessionParams) {
		select {
		case <-promptRelease:
		default:
			close(promptRelease)
		}
	}
	h := newWireTestHandle(t, agent)
	toolStarted := make(chan struct{}, 1)
	turnDone := make(chan provider.RuntimeEvent, 1)
	h.runtimeEventListener = func(event provider.RuntimeEvent) {
		switch event.Type {
		case provider.RuntimeEventItemStarted:
			select {
			case toolStarted <- struct{}{}:
			default:
			}
		case provider.RuntimeEventTurnCompleted:
			turnDone <- event
		}
	}
	h.bindSession("thread-1", "sess")
	h.ensureSessionStream("sess")

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "run"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	select {
	case <-toolStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("tool never started")
	}
	if err := h.InterruptTurn(context.Background(), provider.InterruptTurnInput{ThreadID: "thread-1", TurnID: "turn-1"}); err != nil {
		t.Fatalf("InterruptTurn: %v", err)
	}
	select {
	case event := <-turnDone:
		if event.Payload.TurnState != provider.RuntimeTurnCancelled {
			t.Fatalf("turn completion = %#v, want cancelled", event)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for cancelled turn completion")
	}

	deadline := time.Now().Add(2 * time.Second)
	for {
		h.mu.Lock()
		remaining := 0
		if session := h.sessions["sess"]; session != nil {
			remaining = len(session.toolStates)
		}
		h.mu.Unlock()
		if remaining == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("interrupted turn left %d tool reconciliation entries, want 0 at turn end", remaining)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// Pins the §5 handoff claim: if the turn is interrupted while a steering
// prompt is still waiting for the cancelled prompt to settle, the steer must
// settle as cancelled WITHOUT dispatching — otherwise the agent starts fresh
// work after the user hit stop.
func TestInterruptWhileSteeringWaitsForHandoffSkipsDispatch(t *testing.T) {
	firstPromptStarted := make(chan struct{})
	firstPromptRelease := make(chan struct{})
	cancelCalls := make(chan struct{}, 2)
	var promptMu sync.Mutex
	promptCalls := 0
	agent := &fakeWireAgent{}
	agent.onPrompt = func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
		promptMu.Lock()
		promptCalls++
		call := promptCalls
		promptMu.Unlock()
		if call == 1 {
			close(firstPromptStarted)
			<-firstPromptRelease
			a.respond(id, map[string]any{"stopReason": "cancelled"})
			return
		}
		a.respond(id, map[string]any{"stopReason": "end_turn"})
	}
	agent.onCancel = func(a *fakeWireAgent, params wireSessionParams) {
		select {
		case cancelCalls <- struct{}{}:
		default:
		}
	}
	h := newWireTestHandle(t, agent)
	turnEvents := make(chan provider.RuntimeEvent, 8)
	h.runtimeEventListener = func(event provider.RuntimeEvent) {
		if event.Type == provider.RuntimeEventTurnCompleted {
			turnEvents <- event
		}
	}
	h.bindSession("thread-1", "sess")
	h.ensureSessionStream("sess")

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "first"}); err != nil {
		t.Fatalf("first SendTurn: %v", err)
	}
	select {
	case <-firstPromptStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("first prompt did not start")
	}
	// Steer while the first prompt is in flight, then interrupt while the
	// steer is still waiting for the cancelled prompt to settle.
	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "steer"}); err != nil {
		t.Fatalf("steering SendTurn: %v", err)
	}
	select {
	case <-cancelCalls:
	case <-time.After(2 * time.Second):
		t.Fatal("steering prompt did not send session/cancel")
	}
	if err := h.InterruptTurn(context.Background(), provider.InterruptTurnInput{ThreadID: "thread-1", TurnID: "turn-1"}); err != nil {
		t.Fatalf("InterruptTurn: %v", err)
	}
	close(firstPromptRelease)

	select {
	case event := <-turnEvents:
		if event.TurnID != "turn-1" || event.Payload.TurnState != provider.RuntimeTurnCancelled {
			t.Fatalf("turn completion = %#v, want turn-1 cancelled", event)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for cancelled turn completion")
	}
	promptMu.Lock()
	calls := promptCalls
	promptMu.Unlock()
	if calls != 1 {
		t.Fatalf("prompt calls = %d, want 1 (interrupted steer must not dispatch)", calls)
	}
	select {
	case event := <-turnEvents:
		t.Fatalf("extra turn completion = %#v, want exactly one", event)
	case <-time.After(50 * time.Millisecond):
	}
	waitForNoActiveCollector(t, h, "sess")
}

// Regression: an interrupt naming a turn that is no longer active (stale
// turn id) must not fall through to a session-wide session/cancel — that
// cancels the NEWER prompt running on the session.
func TestInterruptTurnWithStaleTurnIDDoesNotCancelNewerPrompt(t *testing.T) {
	promptStarted := make(chan struct{})
	promptRelease := make(chan struct{})
	cancelCalls := make(chan struct{}, 1)
	agent := &fakeWireAgent{}
	agent.onPrompt = func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
		close(promptStarted)
		<-promptRelease
		a.respond(id, map[string]any{"stopReason": "end_turn"})
	}
	agent.onCancel = func(a *fakeWireAgent, _ wireSessionParams) {
		select {
		case cancelCalls <- struct{}{}:
		default:
		}
	}
	h := newWireTestHandle(t, agent)
	turnEvents := make(chan provider.RuntimeEvent, 8)
	h.runtimeEventListener = func(event provider.RuntimeEvent) {
		if event.Type == provider.RuntimeEventTurnCompleted {
			turnEvents <- event
		}
	}
	h.bindSession("thread-1", "sess")
	h.ensureSessionStream("sess")

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-2", Input: "newer"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	select {
	case <-promptStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("prompt did not start")
	}

	// Stale interrupt for a turn that already completed elsewhere.
	if err := h.InterruptTurn(context.Background(), provider.InterruptTurnInput{ThreadID: "thread-1", TurnID: "turn-1"}); err != nil {
		t.Fatalf("stale InterruptTurn err = %v, want nil no-op", err)
	}
	select {
	case <-cancelCalls:
		t.Fatal("stale interrupt sent session/cancel, cancelling the newer prompt")
	case <-time.After(50 * time.Millisecond):
	}

	close(promptRelease)
	select {
	case event := <-turnEvents:
		if event.TurnID != "turn-2" || event.Payload.TurnState != provider.RuntimeTurnCompleted {
			t.Fatalf("turn completion = %#v, want turn-2 completed (not cancelled)", event)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for newer turn completion")
	}
}

func TestAgentExitAbandonsPromptAndUnbindsDeadSession(t *testing.T) {
	promptEntered := make(chan struct{})
	agent := &fakeWireAgent{}
	agent.onPrompt = func(_ *fakeWireAgent, _ json.RawMessage, _ wireSessionParams) {
		select {
		case <-promptEntered:
		default:
			close(promptEntered)
		}
		// Simulate an in-flight prompt when the agent process exits: the RPC never
		// resolves normally, so stream abandonment is the only settle path.
	}
	h := newWireTestHandle(t, agent)
	turnEvents := make(chan provider.RuntimeEvent, 8)
	h.runtimeEventListener = func(event provider.RuntimeEvent) {
		if event.Type == provider.RuntimeEventTurnCompleted {
			turnEvents <- event
		}
	}

	if _, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	select {
	case <-promptEntered:
	case <-time.After(2 * time.Second):
		t.Fatal("prompt was not dispatched")
	}

	agent.closeTransport()

	select {
	case event := <-turnEvents:
		if event.ThreadID != "thread-1" || event.TurnID != "turn-1" || event.Payload.TurnState != provider.RuntimeTurnFailed {
			t.Fatalf("turn completion = %#v, want failed turn-1 on thread-1", event)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for prompt failure after agent exit")
	}
	waitForSessionUnbound(t, h, "thread-1", "sess")

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := h.StartSession(ctx, provider.StartSessionInput{ThreadID: "thread-1"}); err == nil {
		t.Fatal("StartSession after agent exit succeeded by reusing a dead stream, want connection error")
	}
}

func TestPromptOnStaleSessionUnbindsSoNextPromptStartsFreshSession(t *testing.T) {
	var sessionMu sync.Mutex
	newSessionCalls := 0
	agent := &fakeWireAgent{}
	agent.onNewSession = func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
		sessionMu.Lock()
		newSessionCalls++
		call := newSessionCalls
		sessionMu.Unlock()
		a.respond(id, map[string]any{"sessionId": fmt.Sprintf("sess-%d", call)})
	}
	agent.onPrompt = func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
		if params.SessionID == "sess-1" {
			a.respondError(id, -32002, "Session not found")
			return
		}
		a.respond(id, map[string]any{"stopReason": "end_turn"})
	}
	h := newWireTestHandle(t, agent)
	turnEvents := make(chan provider.RuntimeEvent, 8)
	h.runtimeEventListener = func(event provider.RuntimeEvent) {
		if event.Type == provider.RuntimeEventTurnCompleted {
			turnEvents <- event
		}
	}

	if _, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	select {
	case event := <-turnEvents:
		if event.Payload.TurnState != provider.RuntimeTurnFailed || !strings.Contains(event.Payload.Message, "fresh session") {
			t.Fatalf("stale-session turn completion = %#v, want failed turn with fresh-session guidance", event)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for stale-session turn failure")
	}
	if got := h.sessionIDForThread("thread-1"); got != "" {
		t.Fatalf("thread still bound to %q after stale-session prompt failure, want unbound", got)
	}

	if _, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StartSession after stale session: %v", err)
	}
	sessionMu.Lock()
	calls := newSessionCalls
	sessionMu.Unlock()
	if calls != 2 || h.sessionIDForThread("thread-1") != "sess-2" {
		t.Fatalf("session/new calls = %d, bound = %q, want fresh sess-2 binding", calls, h.sessionIDForThread("thread-1"))
	}
	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-2", Input: "again"}); err != nil {
		t.Fatalf("SendTurn after fresh session: %v", err)
	}
	select {
	case event := <-turnEvents:
		if event.Payload.TurnState != provider.RuntimeTurnCompleted {
			t.Fatalf("fresh-session turn completion = %#v, want completed turn", event)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for fresh-session turn completion")
	}
}

func waitForSessionUnbound(t *testing.T, h *Instance, threadID string, sessionID string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		h.mu.Lock()
		bound := h.sessionsByThread[threadID]
		session := h.sessions[sessionID]
		h.mu.Unlock()
		if bound == "" && session == nil {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	h.mu.Lock()
	bound := h.sessionsByThread[threadID]
	session := h.sessions[sessionID]
	h.mu.Unlock()
	t.Fatalf("thread still bound to %q with session %#v after session stream closed", bound, session)
}

func waitForNoActiveCollector(t *testing.T, h *Instance, sessionID string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	registeredCollector := func() *promptCollector {
		h.mu.Lock()
		defer h.mu.Unlock()
		if session := h.sessions[sessionID]; session != nil {
			return session.collector
		}
		return nil
	}
	for time.Now().Before(deadline) {
		if registeredCollector() == nil {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("collector still active after turn settled: %#v", registeredCollector())
}
