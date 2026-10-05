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
	SessionID             string   `json:"sessionId"`
	Cwd                   string   `json:"cwd"`
	AdditionalDirectories []string `json:"additionalDirectories"`
	Cursor                string   `json:"cursor"`
	ConfigID              string   `json:"configId"`
	Type                  string   `json:"type"`
	Value                 any      `json:"value"`
	ModeID                string   `json:"modeId"`
	MethodID              string   `json:"methodId"`
	Prompt                []struct {
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

	onInitialize      func(params json.RawMessage)
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
		if a.onInitialize != nil {
			a.onInitialize(msg.Params)
		}
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
	agent := &fakeWireAgent{responses: make(chan wireMsg, 2)}
	newWireTestHandle(t, agent)

	// Every fs/* and terminal/* client method is left unregistered, so one of
	// each family covers the shared method-not-found path.
	requests := []struct {
		id     string
		method string
		params map[string]any
	}{
		{id: "fs-read", method: "fs/read_text_file", params: map[string]any{"sessionId": "sess", "path": "/tmp/file"}},
		{id: "terminal-create", method: "terminal/create", params: map[string]any{"sessionId": "sess", "command": "pwd"}},
	}
	for _, request := range requests {
		agent.write(map[string]any{"jsonrpc": "2.0", "id": request.id, "method": request.method, "params": request.params})
	}

	seen := make(map[string]struct{}, len(requests))
	for range requests {
		response := waitFor(t, agent.responses, "timed out waiting for unsupported client-method response")
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

func wireModelAndReasoningOptions(model string, reasoning string) []any {
	return []any{
		map[string]any{
			"type": "select", "id": "z-model", "name": "Model", "category": "model", "currentValue": model,
			"options": []any{
				map[string]any{"value": "model-a", "name": "Model A"},
				map[string]any{"value": "model-b", "name": "Model B"},
			},
		},
		map[string]any{
			"type": "select", "id": "a-reasoning", "name": "Reasoning", "category": "thought_level", "currentValue": reasoning,
			"options": []any{
				map[string]any{"value": "low", "name": "Low"},
				map[string]any{"value": "high", "name": "High"},
			},
		},
	}
}

// --- conversion / pure unit tests -------------------------------------------

func TestContentBlocksGateAttachmentsOnCapability(t *testing.T) {
	for _, tc := range []struct {
		name       string
		attachment provider.Attachment
		enabled    provider.PromptContentCapabilities
		check      func(schema.ContentBlock) bool
	}{
		{
			name:       "embedded resource",
			attachment: provider.Attachment{Kind: "resource", URI: "file:///tmp/context.txt", MimeType: "text/plain", Data: "context"},
			enabled:    provider.PromptContentCapabilities{EmbeddedContext: true},
			check: func(block schema.ContentBlock) bool {
				return block.Type == schema.ContentBlockTypeResource && block.Resource != nil && block.Resource.URI == "file:///tmp/context.txt" && block.Resource.Text != nil && *block.Resource.Text == "context"
			},
		},
		{
			name:       "image",
			attachment: provider.Attachment{Kind: "image", Data: "base64data", MimeType: "image/png"},
			enabled:    provider.PromptContentCapabilities{Image: true},
			check: func(block schema.ContentBlock) bool {
				return block.Type == schema.ContentBlockTypeImage && block.Data != nil && *block.Data == "base64data" && block.MimeType != nil && *block.MimeType == "image/png"
			},
		},
	} {
		input := provider.SendTurnInput{Attachments: []provider.Attachment{tc.attachment}}
		if _, err := contentBlocks(input, provider.PromptContentCapabilities{}); err == nil {
			t.Fatalf("%s: expected an error without the prompt capability", tc.name)
		}
		blocks, err := contentBlocks(input, tc.enabled)
		if err != nil {
			t.Fatalf("%s: contentBlocks: %v", tc.name, err)
		}
		if len(blocks) != 1 || !tc.check(blocks[0]) {
			t.Fatalf("%s: blocks = %#v", tc.name, blocks)
		}
	}
}

func TestContentBlocksPreserveStableResourceAndAnnotationMetadata(t *testing.T) {
	priority := 0.75
	size := int64(42)
	block := schema.ContentBlock{
		Type:        schema.ContentBlockTypeResourceLink,
		Name:        stringPtr("Spec"),
		Title:       stringPtr("ACP specification"),
		Description: stringPtr("Protocol reference"),
		URI:         stringPtr("https://agentclientprotocol.com"),
		MimeType:    stringPtr("text/html"),
		Size:        &size,
		Meta:        map[string]any{"source": "agent"},
		Annotations: &schema.Annotations{
			Audience:     []schema.Role{schema.RoleAssistant},
			Priority:     &priority,
			LastModified: stringPtr("2026-08-20T00:00:00Z"),
			Meta:         map[string]any{"hint": "reference"},
		},
	}
	attachment, ok := attachmentFromACPBlock(block)
	if !ok {
		t.Fatal("resource link was not converted")
	}
	if attachment.Title != "ACP specification" || attachment.Description != "Protocol reference" || attachment.Size != size || attachment.URI != "https://agentclientprotocol.com" {
		t.Fatalf("attachment metadata = %#v", attachment)
	}
	if attachment.Annotations == nil || len(attachment.Annotations.Audience) != 1 || attachment.Annotations.Audience[0] != "assistant" || attachment.Annotations.Priority == nil || *attachment.Annotations.Priority != priority || attachment.Annotations.LastModified == "" {
		t.Fatalf("attachment annotations = %#v", attachment.Annotations)
	}

	blocks, err := contentBlocks(provider.SendTurnInput{Attachments: []provider.Attachment{attachment}}, provider.PromptContentCapabilities{})
	if err != nil {
		t.Fatalf("round-trip resource link: %v", err)
	}
	if len(blocks) != 1 || blocks[0].Title == nil || *blocks[0].Title != "ACP specification" || blocks[0].Annotations == nil || blocks[0].Annotations.Priority == nil || *blocks[0].Annotations.Priority != priority {
		t.Fatalf("round-trip blocks = %#v", blocks)
	}
}

func TestConfigChoicesPreserveDescriptionsAndGroups(t *testing.T) {
	description := "Use the faster model"
	choices := configChoices([]schema.SessionConfigSelectGroup{{
		Group: "speed", Name: "Speed",
		Options: []schema.SessionConfigSelectOption{{Value: "fast", Name: "Fast", Description: &description}},
	}})
	if len(choices) != 1 || choices[0].Value != "fast" || choices[0].Description != description || choices[0].Group != "speed" || choices[0].GroupLabel != "Speed" {
		t.Fatalf("choices = %#v", choices)
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

// newPermissionTestInstance binds thread-1 to "sess" with live turn-1 and
// reports every opened approval's request id.
func newPermissionTestInstance() (*Instance, <-chan string) {
	opened := make(chan string, 2)
	h := newInstance(func(event provider.RuntimeEvent) {
		if event.Type == provider.RuntimeEventRequestOpened {
			opened <- event.RequestID
		}
	})
	bindTestSession(h, "thread-1", "sess").collector = &promptCollector{threadID: "thread-1", turnID: "turn-1"}
	return h, opened
}

// requestPermissionAsync issues the agent's permission request for toolCallID
// on session "sess" and delivers the eventual response.
func requestPermissionAsync(ctx context.Context, h *Instance, toolCallID string) <-chan schema.RequestPermissionResponse {
	done := make(chan schema.RequestPermissionResponse, 1)
	go func() {
		resp, _ := h.requestPermission(ctx, schema.RequestPermissionRequest{SessionID: "sess", ToolCall: schema.ToolCallUpdate{ToolCallID: schema.ToolCallId(toolCallID)}, Options: permissionOptions()})
		done <- resp
	}()
	return done
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
	// The stable agent-method path is owned by the daemon's provider
	// authenticate/logout RPC test.
}

func TestSessionUpdateMapsAvailableCommands(t *testing.T) {
	event := sessionRuntimeEvent(testSessionNotification(t, `{"sessionId":"sess","update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"review","description":"Review changes","input":{"hint":"[commit]"}}]}}`))
	if len(event.Payload.SlashCommands) != 1 {
		t.Fatalf("slash commands = %#v, want one command", event.Payload.SlashCommands)
	}
	if command := event.Payload.SlashCommands[0]; command.Name != "review" || !command.HasInput || command.InputHint != "[commit]" {
		t.Fatalf("slash command = %#v, want input hint preserved", command)
	}

	// An explicit empty list must still serialize so clients clear stale commands.
	event = sessionRuntimeEvent(testSessionNotification(t, `{"sessionId":"sess","update":{"sessionUpdate":"available_commands_update","availableCommands":[]}}`))
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

func TestSeparateReplayReasoningBlocksAddsParagraphBreaks(t *testing.T) {
	reasoning := func(delta string) provider.RuntimeEvent {
		return provider.RuntimeEvent{
			Type:    provider.RuntimeEventContentDelta,
			Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: delta},
		}
	}
	events := []provider.RuntimeEvent{
		reasoning("**Considering options**"),
		reasoning("**Choosing an approach**\n"),
		reasoning(""),
		{
			Type:    provider.RuntimeEventContentDelta,
			Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "answer"},
		},
	}

	separateReplayReasoningBlocks(events)

	if events[0].Payload.Delta != "**Considering options**\n\n" {
		t.Fatalf("delta = %q, want trailing paragraph break", events[0].Payload.Delta)
	}
	if events[1].Payload.Delta != "**Choosing an approach**\n" {
		t.Fatalf("delta = %q, want newline-terminated block untouched", events[1].Payload.Delta)
	}
	if events[2].Payload.Delta != "" {
		t.Fatalf("delta = %q, want empty block untouched", events[2].Payload.Delta)
	}
	if events[3].Payload.Delta != "answer" {
		t.Fatalf("delta = %q, want assistant text untouched", events[3].Payload.Delta)
	}
}

func TestSessionUpdateMapsPlan(t *testing.T) {
	var notification schema.SessionNotification
	if err := json.Unmarshal([]byte(`{"sessionId":"sess","update":{"sessionUpdate":"plan","entries":[{"content":"Do it","priority":"high","status":"pending"}]}}`), &notification); err != nil {
		t.Fatalf("decode plan update: %v", err)
	}
	event := sessionRuntimeEvent(notification)
	if event.Type != provider.RuntimeEventTurnPlanUpdated || len(event.Payload.PlanEntries) != 1 {
		t.Fatalf("event = %#v, want one plan entry", event)
	}
	if entry := event.Payload.PlanEntries[0]; entry.Content != "Do it" || string(entry.Priority) != "high" || string(entry.Status) != "pending" {
		t.Fatalf("plan entry = %#v, want high-priority pending entry", entry)
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

// Regression (leak): stray updates draining from a disposed stream
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
	waitFor(t, updateEntered, "prior session update did not enter the stream consumer")

	permissionDone := requestPermissionAsync(context.Background(), h, "tool-1")
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
	resp := waitFor(t, permissionDone, "permission response did not complete")
	if selectedOption(resp) != "allow" {
		t.Fatalf("permission outcome = %#v, want allow", resp.Outcome)
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

	done := requestPermissionAsync(context.Background(), h, "tool_1")
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

	resp := waitFor(t, done, "terminal tool update did not resolve pending permission")
	if resp.Outcome.Outcome != schema.RequestPermissionOutcomeOutcomeCancelled {
		t.Fatalf("permission outcome = %#v, want cancelled", resp.Outcome)
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

	done := requestPermissionAsync(context.Background(), h, "tool_1")
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

	done := requestPermissionAsync(context.Background(), h, "tool_1")
	requestID := <-opened
	if err := h.RespondToRequest(context.Background(), provider.RespondToRequestInput{ThreadID: "thread-1", RequestID: requestID, Decision: provider.ApprovalDecisionAccept}); err == nil {
		t.Fatal("RespondToRequest accepted an approval for an already-settled tool")
	}
	close(releaseOpened)
	resp := waitFor(t, done, "permission stayed pending after its tool had already settled")
	if resp.Outcome.Outcome != schema.RequestPermissionOutcomeOutcomeCancelled {
		t.Fatalf("permission outcome = %#v, want cancelled", resp.Outcome)
	}
}

// Regression (retry-after-decline): within one turn, a NEW tool_call reusing
// a settled tool-call id re-opens the approval cycle, so a fresh
// session/request_permission for that id must reach the client instead of
// being auto-cancelled by the stale settled marker.
func TestPermissionAnswerableAfterToolCallIDReusedInSameTurn(t *testing.T) {
	h, opened := newPermissionTestInstance()

	// Tool X runs and settles (declined) within the turn...
	h.handleACPSessionUpdate(testSessionNotification(t, `{"sessionId":"sess","update":{"sessionUpdate":"tool_call","toolCallId":"tool_1","title":"Edit","kind":"edit","status":"pending"}}`))
	h.handleACPSessionUpdate(testSessionNotification(t, `{"sessionId":"sess","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool_1","status":"failed"}}`))
	// ...then the agent retries: a NEW tool_call with the same id.
	h.handleACPSessionUpdate(testSessionNotification(t, `{"sessionId":"sess","update":{"sessionUpdate":"tool_call","toolCallId":"tool_1","title":"Edit","kind":"edit","status":"pending"}}`))

	done := requestPermissionAsync(context.Background(), h, "tool_1")
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
	resp := waitFor(t, done, "re-opened permission was not resolved by the client answer")
	if selectedOption(resp) != "allow" {
		t.Fatalf("permission outcome = %#v, want client-selected allow", resp.Outcome)
	}
}

// Regression: a duplicate concurrent permission request for the same key
// overwrites the cancel registration; the first request's cleanup must not
// unregister the second's cancel, or an interrupt can no longer resolve it.
func TestDuplicatePermissionRequestKeepsCancelRegistration(t *testing.T) {
	h, opened := newPermissionTestInstance()

	firstCtx, cancelFirst := context.WithCancel(context.Background())
	defer cancelFirst()
	firstDone := requestPermissionAsync(firstCtx, h, "tool_1")
	waitFor(t, opened, "first permission request was never published")
	secondDone := requestPermissionAsync(context.Background(), h, "tool_1")
	waitFor(t, opened, "duplicate permission request was never published")

	// First request resolves (agent-side cancel); its cleanup runs.
	cancelFirst()
	waitFor(t, firstDone, "first permission request did not resolve after its context was cancelled")

	// An interrupt must still find and cancel the second (live) request.
	if !h.promptCancellationMatches("sess", "turn-1") {
		t.Fatal("turn-1 is not a cancellation target")
	}
	cancels, _, _ := h.markPromptCancelled("sess", "turn-1")
	if len(cancels) != 1 {
		t.Fatalf("interrupt found %d pending permission cancels, want the duplicate request still registered", len(cancels))
	}
	for _, cancel := range cancels {
		cancel()
	}
	resp := waitFor(t, secondDone, "duplicate permission request was orphaned: interrupt could not cancel it")
	if resp.Outcome.Outcome != schema.RequestPermissionOutcomeOutcomeCancelled {
		t.Fatalf("duplicate permission outcome = %#v, want cancelled by interrupt", resp.Outcome)
	}
}

func TestRespondToRequestSelectsExplicitOptionOrDecisionFallback(t *testing.T) {
	h, opened := newPermissionTestInstance()
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
	if !h.promptCancellationMatches("sess", "turn-1") {
		t.Fatal("expected turn-1 to be a cancellation target")
	}
	h.markPromptCancelled("sess", "turn-1")
	if session := h.sessionForThreadLocked("thread-1"); session == nil || !session.collector.cancelled {
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
	bindStreamingSession(h)
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
	sessionID := waitFor(t, closed, "never-used session did not call session/close")
	if sessionID != "sess" {
		t.Fatalf("closed session = %q, want sess", sessionID)
	}
	if got := h.sessionIDForThread("thread-draft"); got != "" {
		t.Fatalf("thread binding after close = %q, want unbound", got)
	}
}

func TestStopSessionCancelsThenClosesActiveSessionWhenSupported(t *testing.T) {
	promptStarted := make(chan struct{})
	promptRelease := make(chan struct{})
	cancelled := make(chan struct{})
	closed := make(chan string, 1)
	agent := &fakeWireAgent{
		capabilities: map[string]any{"sessionCapabilities": map[string]any{"close": map[string]any{}}},
		onPrompt: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			close(promptStarted)
			<-promptRelease
			a.respond(id, map[string]any{"stopReason": "cancelled"})
		},
		onCancel: func(_ *fakeWireAgent, _ wireSessionParams) {
			close(cancelled)
		},
		onCloseSession: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			select {
			case <-cancelled:
			case <-time.After(time.Second):
				a.t.Error("session/close arrived before session/cancel")
			}
			closed <- params.SessionID
			close(promptRelease)
			a.respond(id, map[string]any{})
		},
	}
	h := newWireTestHandle(t, agent)
	if _, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "work"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	waitFor(t, promptStarted, "prompt did not start")
	if err := h.StopSession(context.Background(), provider.StopSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StopSession: %v", err)
	}
	sessionID := waitFor(t, closed, "active session was cancelled but not closed")
	if sessionID != "sess" {
		t.Fatalf("closed session = %q, want sess", sessionID)
	}
	if got := h.sessionIDForThread("thread-1"); got != "" {
		t.Fatalf("thread binding after close = %q, want unbound", got)
	}
}

func TestStopSessionCloseTimeoutKeepsBindingForRetry(t *testing.T) {
	promptStarted := make(chan struct{})
	promptRelease := make(chan struct{})
	agent := &fakeWireAgent{
		capabilities: map[string]any{"sessionCapabilities": map[string]any{"close": map[string]any{}}},
		onPrompt: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			close(promptStarted)
			<-promptRelease
			a.respond(id, map[string]any{"stopReason": "cancelled"})
		},
		onCloseSession: func(_ *fakeWireAgent, _ json.RawMessage, _ wireSessionParams) {
			// Deliberately leave the request pending until its context expires.
		},
	}
	h := newWireTestHandle(t, agent)
	t.Cleanup(func() { close(promptRelease) })
	if _, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "work"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	waitFor(t, promptStarted, "prompt did not start")
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()
	if err := h.StopSession(ctx, provider.StopSessionInput{ThreadID: "thread-1"}); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("StopSession err = %v, want context deadline", err)
	}
	if got := h.sessionIDForThread("thread-1"); got != "sess" {
		t.Fatalf("thread binding after timed-out close = %q, want sess retained for retry", got)
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
	bindStreamingSession(h)

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "work"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	waitFor(t, promptStarted, "prompt did not start")
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
	event := waitFor(t, events, "timed out waiting for current mode update")
	if len(event.Payload.ConfigOptions) != 1 || event.Payload.ConfigOptions[0].CurrentValue != "architect" || len(event.Payload.ConfigOptions[0].Choices) != 2 || event.Payload.ConfigOptions[0].Choices[0].Value != "code" || event.Payload.ConfigOptions[0].Choices[1].Value != "architect" {
		t.Fatalf("config options event = %#v, want architect current mode", event)
	}
}

// Legacy Session Modes are projected as the acp.session-mode option; both the
// start-time restore and explicit SetConfigOption must route to session/set_mode.
func TestLegacySessionModeSelectionUsesSetMode(t *testing.T) {
	modeCalls := make(chan wireSessionParams, 2)
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
	if err := h.SetConfigOption(context.Background(), provider.SetConfigOptionInput{ThreadID: "thread-1", OptionID: acpSessionModeOptionID, Value: "code"}); err != nil {
		t.Fatalf("SetConfigOption: %v", err)
	}
	for _, want := range []string{"architect", "code"} {
		select {
		case call := <-modeCalls:
			if call.ModeID != want {
				t.Fatalf("session/set_mode modeId = %q, want %q", call.ModeID, want)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("session/set_mode was not called for %q", want)
		}
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

	result, err := h.StartSession(context.Background(), provider.StartSessionInput{
		ThreadID:       "thread-1",
		ModelSelection: &provider.ModelSelection{Model: "model-b"},
		ConfigSelections: []provider.ConfigOptionSelection{{
			OptionID: "model",
			Value:    "model-b",
			Category: provider.ConfigOptionCategoryModel,
		}},
	})
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

func TestStartSessionInfersMissingCategoriesAndAppliesModelFirst(t *testing.T) {
	recorder := &callRecorder{}
	model := "model-a"
	reasoning := "low"
	agent := &fakeWireAgent{
		onNewSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			a.respond(id, map[string]any{
				"sessionId":     "sess",
				"configOptions": wireModelAndReasoningOptions(model, reasoning),
			})
		},
		onSetConfigOption: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			recorder.recordConfig(params)
			switch params.ConfigID {
			case "z-model":
				model = params.stringValue()
			case "a-reasoning":
				reasoning = params.stringValue()
			}
			a.respond(id, map[string]any{
				"configOptions": wireModelAndReasoningOptions(model, reasoning),
			})
		},
	}
	h := newWireTestHandle(t, agent)

	_, err := h.StartSession(context.Background(), provider.StartSessionInput{
		ThreadID: "thread-1",
		// The client can Send before its options catalog loads, so these
		// selections intentionally omit category and arrive dependent-first.
		ConfigSelections: []provider.ConfigOptionSelection{
			{OptionID: "a-reasoning", Value: "high"},
			{OptionID: "z-model", Value: "model-b"},
		},
	})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	calls := recorder.configCalls()
	if len(calls) != 2 ||
		calls[0].ConfigID != "z-model" || calls[0].Value != "model-b" ||
		calls[1].ConfigID != "a-reasoning" || calls[1].Value != "high" {
		t.Fatalf("set_config_option calls = %#v, want model before reasoning", calls)
	}
}

// StartSession runs before EVERY prompt with the thread's stored model
// preference, on both the session/new and the in-process reuse branch. A
// preference that no longer matches a config choice must downgrade to a runtime
// warning; failing would brick the thread (every turn failing with the same
// error) — a regression the reuse branch once had.
func TestStartSessionWarnsWhenModelPreferenceCannotBeApplied(t *testing.T) {
	agent := &fakeWireAgent{
		onNewSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			a.respond(id, map[string]any{"sessionId": "sess", "configOptions": wireModeConfigOptions("code")})
		},
	}
	h := newWireTestHandle(t, agent)
	input := provider.StartSessionInput{ThreadID: "thread-1", ModelSelection: &provider.ModelSelection{Model: "model-b"}}

	for _, branch := range []string{"new", "reuse"} {
		recorder := &eventRecorder{}
		h.runtimeEventListener = recorder.listener
		result, err := h.StartSession(context.Background(), input)
		if err != nil {
			t.Fatalf("%s StartSession with stale model preference err = %v, want warning instead of failure", branch, err)
		}
		if result.Session.ProviderSessionID != "sess" || h.sessionIDForThread("thread-1") != "sess" {
			t.Fatalf("%s session = %#v, want sess binding", branch, result.Session)
		}
		events := recorder.snapshot()
		if len(events) != 1 || events[0].Type != provider.RuntimeEventRuntimeWarning || !strings.Contains(events[0].Payload.Message, "model-b") {
			t.Fatalf("%s events = %#v, want one model preference warning", branch, events)
		}
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
		capabilities: map[string]any{"sessionCapabilities": map[string]any{
			"list":                  map[string]any{},
			"delete":                map[string]any{},
			"close":                 map[string]any{},
			"additionalDirectories": map[string]any{},
		}},
		onListSessions: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			mu.Lock()
			cursors = append(cursors, params.Cursor)
			mu.Unlock()
			if params.Cursor == "" {
				a.respond(id, map[string]any{"sessions": []any{map[string]any{"sessionId": "one", "cwd": "/tmp"}}, "nextCursor": "page-2"})
				return
			}
			a.respond(id, map[string]any{"sessions": []any{map[string]any{"sessionId": "two", "cwd": "/tmp", "additionalDirectories": []string{"/workspace-b", "/workspace-c"}}}})
		},
	}
	h := newWireTestHandle(t, agent)
	caps := h.Info().Capabilities
	if !caps.SessionList || !caps.SessionDelete || !caps.SessionClose || !caps.AdditionalDirectories {
		t.Fatalf("session capabilities = %#v, want list/delete/close/additionalDirectories", caps)
	}
	sessions, err := h.ListSessions(context.Background(), "/tmp")
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(sessions) != 2 || sessions[0].SessionID != "one" || sessions[1].SessionID != "two" {
		t.Fatalf("sessions = %#v, want both pages", sessions)
	}
	if got := sessions[1].AdditionalDirectories; len(got) != 2 || got[0] != "/workspace-b" || got[1] != "/workspace-c" {
		t.Fatalf("additional directories = %#v, want ordered roots from session/list", got)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(cursors) != 2 || cursors[0] != "" || cursors[1] != "page-2" {
		t.Fatalf("cursors = %#v, want empty then page-2", cursors)
	}
}

func TestStartSessionSendsAdditionalDirectoriesAcrossLifecycleMethods(t *testing.T) {
	tests := []struct {
		name         string
		capabilities map[string]any
		cursor       json.RawMessage
		configure    func(*fakeWireAgent, *callRecorder)
	}{
		{
			name:         "new",
			capabilities: map[string]any{"sessionCapabilities": map[string]any{"additionalDirectories": map[string]any{}}},
			configure: func(agent *fakeWireAgent, recorder *callRecorder) {
				agent.onNewSession = func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
					recorder.recordConfig(params)
					a.respond(id, map[string]any{"sessionId": "sess"})
				}
			},
		},
		{
			name: "load",
			capabilities: map[string]any{
				"loadSession":         true,
				"sessionCapabilities": map[string]any{"additionalDirectories": map[string]any{}},
			},
			cursor: marshalRaw(map[string]string{"sessionId": "old"}),
			configure: func(agent *fakeWireAgent, recorder *callRecorder) {
				agent.onLoadSession = func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
					recorder.recordConfig(params)
					a.respond(id, map[string]any{})
				}
			},
		},
		{
			name: "resume",
			capabilities: map[string]any{
				"sessionCapabilities": map[string]any{
					"resume":                map[string]any{},
					"additionalDirectories": map[string]any{},
				},
			},
			cursor: marshalRaw(map[string]string{"sessionId": "old"}),
			configure: func(agent *fakeWireAgent, recorder *callRecorder) {
				agent.onResumeSession = func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
					recorder.recordConfig(params)
					a.respond(id, map[string]any{})
				}
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			recorder := &callRecorder{}
			agent := &fakeWireAgent{capabilities: test.capabilities}
			test.configure(agent, recorder)
			h := newWireTestHandle(t, agent)
			result, err := h.StartSession(context.Background(), provider.StartSessionInput{
				ThreadID:              "thread-1",
				Cwd:                   "/workspace-a",
				AdditionalDirectories: []string{"/workspace-b", "/workspace-c"},
				ResumeCursor:          test.cursor,
			})
			if err != nil {
				t.Fatalf("StartSession: %v", err)
			}
			calls := recorder.configCalls()
			if len(calls) != 1 {
				t.Fatalf("lifecycle calls = %d, want 1", len(calls))
			}
			if got := calls[0].AdditionalDirectories; len(got) != 2 || got[0] != "/workspace-b" || got[1] != "/workspace-c" {
				t.Fatalf("wire additional directories = %#v, want ordered roots", got)
			}
			if got := result.Session.AdditionalDirectories; len(got) != 2 || got[0] != "/workspace-b" || got[1] != "/workspace-c" {
				t.Fatalf("session projection additional directories = %#v, want ordered roots", got)
			}
		})
	}
}

func TestStartSessionOmitsAdditionalDirectoriesWithoutCapability(t *testing.T) {
	recorder := &callRecorder{}
	agent := &fakeWireAgent{
		onNewSession: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			recorder.recordConfig(params)
			a.respond(id, map[string]any{"sessionId": "sess"})
		},
	}
	h := newWireTestHandle(t, agent)
	result, err := h.StartSession(context.Background(), provider.StartSessionInput{
		ThreadID:              "thread-1",
		Cwd:                   "/workspace-a",
		AdditionalDirectories: []string{"/workspace-b"},
	})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if calls := recorder.configCalls(); len(calls) != 1 || len(calls[0].AdditionalDirectories) != 0 {
		t.Fatalf("session/new calls = %#v, want unsupported additional directories omitted", calls)
	}
	if len(result.Session.AdditionalDirectories) != 0 {
		t.Fatalf("session projection = %#v, want unsupported additional directories omitted", result.Session)
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

// Resume wins over load when both are advertised, and updates the agent emits
// before the resume response still route to the thread.
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
			a.sendUpdate("old", agentMessageUpdate("msg-1", "resumed"))
			a.respond(id, map[string]any{"configOptions": wireModelConfigOptions("model-a")})
		},
	}
	h := newWireTestHandle(t, agent)
	recorder := &eventRecorder{}
	h.runtimeEventListener = recorder.listener

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
	if events := recorder.snapshot(); len(events) != 1 || events[0].ThreadID != "thread-1" || events[0].Payload.Delta != "resumed" {
		t.Fatalf("events = %#v, want resume update routed to thread-1", events)
	}
}

// Wire-level regression for the settled-tool tombstone: agents can resend a
// terminal tool_call_update after the tool already settled. That trailing
// update must reach the listener as a well-formed ItemUpdated (itemType/status
// enriched from the tombstone) with the late output normalized into
// ToolCall.Output rather than exposed as a provider-native rawOutput blob.
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
	bindStreamingSession(h)

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "run"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	waitFor(t, turnDone, "timed out waiting for turn completion")

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
	if trailing.Payload.ToolCall == nil {
		t.Fatal("trailing event lost the normalized tool call")
	}
	if trailing.Payload.ToolCall.Output != "late output" {
		t.Fatalf(
			"trailing tool call output = %q, want late rawOutput normalized",
			trailing.Payload.ToolCall.Output,
		)
	}
	encoded, err := json.Marshal(trailing.Payload.ToolCall)
	if err != nil {
		t.Fatalf("marshal trailing tool call: %v", err)
	}
	if strings.Contains(string(encoded), "rawOutput") {
		t.Fatalf("trailing tool call exposed provider-native raw output blob: %s", encoded)
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
	bindStreamingSession(h)

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "first"}); err != nil {
		t.Fatalf("first SendTurn: %v", err)
	}
	waitFor(t, firstPromptStarted, "first prompt did not start")
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
	waitFor(t, secondPromptStarted, "follow-up prompt did not start after cancelled prompt drained")
	if err := <-followUpDone; err != nil {
		t.Fatalf("follow-up SendTurn: %v", err)
	}
	event := waitFor(t, eventCh, "timed out waiting for follow-up assistant delta")
	if event.TurnID != "turn-2" || event.Payload.Delta != "hello" {
		t.Fatalf("event = %#v, want delivered turn-2 assistant delta", event)
	}
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
	bindStreamingSession(h)

	for _, input := range []string{"first", "steer one", "steer two"} {
		if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: input}); err != nil {
			t.Fatalf("SendTurn(%q): %v", input, err)
		}
		if input == "first" {
			waitFor(t, firstPromptStarted, "first prompt did not start")
		}
	}
	close(firstPromptRelease)
	waitFor(t, allPromptsDone, "queued steering prompts did not all dispatch")
	promptMu.Lock()
	defer promptMu.Unlock()
	want := []string{"first", "steer one", "steer two"}
	if fmt.Sprint(prompts) != fmt.Sprint(want) {
		t.Fatalf("prompt order = %#v, want %#v", prompts, want)
	}
}

// Regression for codex-acp (Zed's own client cancels the running prompt before
// every send): an agent may accept an overlapping session/prompt's text but
// never answer the second RPC, wedging the turn forever. A steering prompt must
// therefore cancel the in-flight prompt, wait for it to settle, then dispatch;
// the cancelled prompt's open tools settle as interrupted and the turn still
// completes normally from the steering prompt.
func TestSteeringPromptCancelsInFlightPromptAndSettlesAbandonedTools(t *testing.T) {
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
	bindStreamingSession(h)

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
	waitFor(t, firstPromptStarted, "first prompt did not start")
	started := waitForEvent("tool start", func(event provider.RuntimeEvent) bool {
		return event.Type == provider.RuntimeEventItemStarted && event.Payload.ItemStatus == provider.ItemStatusInProgress
	})
	if started.Payload.ItemType != provider.ItemKindCommandExecution || started.ThreadID != "thread-1" || started.TurnID != "turn-1" {
		t.Fatalf("tool start = %#v, want command_execution on turn-1", started)
	}

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "steer"}); err != nil {
		t.Fatalf("steering SendTurn: %v", err)
	}
	waitFor(t, cancelCalls, "steering prompt did not send session/cancel")
	select {
	case <-secondPromptStarted:
		t.Fatal("steering prompt dispatched while first prompt still in flight")
	case <-time.After(50 * time.Millisecond):
	}
	close(firstPromptRelease)
	waitFor(t, secondPromptStarted, "steering prompt did not dispatch after cancelled prompt settled")

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
	if completed.TurnID != "turn-1" || completed.Payload.TurnState != provider.RuntimeTurnCompleted {
		t.Fatalf("turn completion = %#v, want turn-1 completed from steering prompt", completed)
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
	bindStreamingSession(h)

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "first"}); err != nil {
		t.Fatalf("first SendTurn: %v", err)
	}
	waitFor(t, completing, "first turn never reached its completion emission")

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

// Regression (leak): an interrupted turn's tool reconciliation
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
	bindStreamingSession(h)

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "run"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	waitFor(t, toolStarted, "tool never started")
	if err := h.InterruptTurn(context.Background(), provider.InterruptTurnInput{ThreadID: "thread-1", TurnID: "turn-1"}); err != nil {
		t.Fatalf("InterruptTurn: %v", err)
	}
	event := waitFor(t, turnDone, "timed out waiting for cancelled turn completion")
	if event.Payload.TurnState != provider.RuntimeTurnCancelled {
		t.Fatalf("turn completion = %#v, want cancelled", event)
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

// If the turn is interrupted while a steering prompt is still waiting for the
// cancelled prompt to settle, the steer must settle as cancelled WITHOUT
// dispatching — otherwise the agent starts fresh work after the user hit stop.
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
	turnEvents := turnCompletions(h)
	bindStreamingSession(h)

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "first"}); err != nil {
		t.Fatalf("first SendTurn: %v", err)
	}
	waitFor(t, firstPromptStarted, "first prompt did not start")
	// Steer while the first prompt is in flight, then interrupt while the
	// steer is still waiting for the cancelled prompt to settle.
	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "steer"}); err != nil {
		t.Fatalf("steering SendTurn: %v", err)
	}
	waitFor(t, cancelCalls, "steering prompt did not send session/cancel")
	if err := h.InterruptTurn(context.Background(), provider.InterruptTurnInput{ThreadID: "thread-1", TurnID: "turn-1"}); err != nil {
		t.Fatalf("InterruptTurn: %v", err)
	}
	close(firstPromptRelease)

	event := waitFor(t, turnEvents, "timed out waiting for cancelled turn completion")
	if event.TurnID != "turn-1" || event.Payload.TurnState != provider.RuntimeTurnCancelled {
		t.Fatalf("turn completion = %#v, want turn-1 cancelled", event)
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
	turnEvents := turnCompletions(h)
	bindStreamingSession(h)

	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-2", Input: "newer"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	waitFor(t, promptStarted, "prompt did not start")

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
	event := waitFor(t, turnEvents, "timed out waiting for newer turn completion")
	if event.TurnID != "turn-2" || event.Payload.TurnState != provider.RuntimeTurnCompleted {
		t.Fatalf("turn completion = %#v, want turn-2 completed (not cancelled)", event)
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
	turnEvents := turnCompletions(h)

	if _, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	waitFor(t, promptEntered, "prompt was not dispatched")

	agent.closeTransport()

	event := waitFor(t, turnEvents, "timed out waiting for prompt failure after agent exit")
	if event.ThreadID != "thread-1" || event.TurnID != "turn-1" || event.Payload.TurnState != provider.RuntimeTurnFailed {
		t.Fatalf("turn completion = %#v, want failed turn-1 on thread-1", event)
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
	turnEvents := turnCompletions(h)

	if _, err := h.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	event := waitFor(t, turnEvents, "timed out waiting for stale-session turn failure")
	if event.Payload.TurnState != provider.RuntimeTurnFailed || !strings.Contains(event.Payload.Message, "fresh session") {
		t.Fatalf("stale-session turn completion = %#v, want failed turn with fresh-session guidance", event)
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
	event = waitFor(t, turnEvents, "timed out waiting for fresh-session turn completion")
	if event.Payload.TurnState != provider.RuntimeTurnCompleted {
		t.Fatalf("fresh-session turn completion = %#v, want completed turn", event)
	}
}

// bindStreamingSession binds thread-1 to the fake agent's "sess" session with
// a live update stream, as StartSession would.
func bindStreamingSession(h *Instance) {
	h.bindSession("thread-1", "sess")
	h.ensureSessionStream("sess")
}

// turnCompletions routes every TurnCompleted runtime event to the returned
// channel, replacing the instance's listener.
func turnCompletions(h *Instance) <-chan provider.RuntimeEvent {
	events := make(chan provider.RuntimeEvent, 8)
	h.runtimeEventListener = func(event provider.RuntimeEvent) {
		if event.Type == provider.RuntimeEventTurnCompleted {
			events <- event
		}
	}
	return events
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

// waitFor receives from ch, failing the test with failure after two seconds.
func waitFor[T any](t *testing.T, ch <-chan T, failure string) T {
	t.Helper()
	select {
	case value := <-ch:
		return value
	case <-time.After(2 * time.Second):
		t.Fatal(failure)
		var zero T
		return zero
	}
}
