package acp

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	acp "github.com/Aqothy/go-acp"
	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/provider/providertest"
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
	// answered lets a prompt hook wait until the test has the answer to a
	// request the hook made.
	answered chan struct{}

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

// testInstance is an instance connected to a fake agent, with a mirror and
// an event recorder.
type testInstance struct {
	*Instance
	events *providertest.Recorder
	mirror *providertest.Mirror
}

// newWireTestHandle connects an Instance to the fake agent over in-memory
// pipes and runs the real initialize handshake.
func newWireTestHandle(t *testing.T, agent *fakeWireAgent) testInstance {
	t.Helper()
	agent.t = t

	agentIn, clientOut := io.Pipe() // client -> agent
	clientIn, agentOut := io.Pipe() // agent -> client
	agent.r = agentIn
	agent.w = agentOut
	go agent.serve(agentIn)

	events, mirror := providertest.NewRecorder(), providertest.NewMirror()
	h := newInstance(provider.Host{Emit: events.Emit, Mirror: mirror})
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
		Capabilities: capabilitySet(initResp, true),
		Auth:         authStateFromACP(initResp),
	}
	return testInstance{Instance: h, events: events, mirror: mirror}
}

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
		input := provider.SendInput{Attachments: []provider.Attachment{tc.attachment}}
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

	blocks, err := contentBlocks(provider.SendInput{Attachments: []provider.Attachment{attachment}}, provider.PromptContentCapabilities{})
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

func TestTerminalAuthMethods(t *testing.T) {
	var methods []schema.AuthMethod
	if err := json.Unmarshal([]byte(`[
		{"type":"_future","id":"future-login","name":"Future"},
		{"type":"terminal","id":"terminal-login","name":"Terminal","args":["--login"],"env":{"MODE":"login"}}
	]`), &methods); err != nil {
		t.Fatalf("decode auth methods: %v", err)
	}
	initResp := schema.InitializeResponse{AuthMethods: methods}
	if !capabilitySet(initResp, false).Auth {
		t.Fatal("a terminal method should advertise auth support")
	}
	if auth := authStateFromACP(initResp); len(auth.Methods) != 1 || auth.Methods[0].ID != "terminal-login" || auth.Methods[0].Kind != provider.AuthKindTerminal {
		t.Fatalf("auth methods = %#v, want only the terminal method", auth.Methods)
	}

	// No agent connection: a terminal method must never reach ACP authenticate.
	h := &Instance{initialize: initResp, config: Config{Command: []string{"agent", "--acp"}, Env: map[string]string{"MODE": "acp", "TOKEN": "x"}}}
	result, err := h.Authenticate(context.Background(), provider.AuthenticateInput{MethodID: "terminal-login"})
	if err != nil || result.Terminal == nil {
		t.Fatalf("Authenticate = %#v, %v; want a terminal command", result, err)
	}
	command := *result.Terminal
	if want := []string{"agent", "--acp", "--login"}; !slices.Equal(command.Argv, want) {
		t.Fatalf("argv = %v, want %v", command.Argv, want)
	}
	// exec keeps the last of duplicated keys, so the method's MODE wins.
	if want := []string{"MODE=acp", "TOKEN=x", "MODE=login"}; !slices.Equal(command.Env, want) {
		t.Fatalf("env = %v, want %v", command.Env, want)
	}
}

// A request refused with auth_required marks the provider signed out, which is
// what makes clients offer sign-in.
func TestAuthRequiredMarksProviderUnauthenticated(t *testing.T) {
	agent := &fakeWireAgent{onNewSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
		a.respondError(id, -32000, "Authentication required")
	}}
	h := newWireTestHandle(t, agent)
	if _, err := h.Open(context.Background(), provider.OpenInput{Workspace: provider.Workspace{Cwd: "/tmp"}}); err == nil {
		t.Fatal("Open err = nil, want auth_required")
	}
	if status := h.Info().Auth.Status; status != provider.AuthStatusUnauthenticated {
		t.Fatalf("auth status = %q, want unauthenticated", status)
	}
}
