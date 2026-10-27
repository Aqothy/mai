package acp

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/provider"
)

// maiD advertises exactly what it implements: no fs or terminal client methods.
func TestInitializeAdvertisesSupportedClientCapabilities(t *testing.T) {
	initializeRequests := make(chan schema.InitializeRequest, 1)
	agent := &fakeWireAgent{
		onInitialize: func(params json.RawMessage) {
			var request schema.InitializeRequest
			if err := json.Unmarshal(params, &request); err != nil {
				t.Errorf("decode initialize request: %v", err)
				return
			}
			initializeRequests <- request
		},
	}
	_ = newWireTestHandle(t, agent)
	caps := waitFor(t, initializeRequests, "initialize request was not observed").ClientCapabilities
	if caps == nil || caps.Session == nil || caps.Session.ConfigOptions == nil || caps.Session.ConfigOptions.Boolean == nil {
		t.Fatalf("client capabilities = %#v, want boolean config options advertised", caps)
	}
	if caps.Elicitation == nil || caps.Elicitation.Form == nil || caps.Elicitation.URL == nil {
		t.Fatalf("elicitation capabilities = %#v, want form and url", caps.Elicitation)
	}
	if caps.Auth == nil || caps.Auth.Terminal == nil || !*caps.Auth.Terminal {
		t.Fatalf("auth capabilities = %#v, want terminal sign-in", caps.Auth)
	}
	if caps.FS != nil || caps.Terminal != nil {
		t.Fatalf("client capabilities = %#v, want fs and terminal unadvertised", caps)
	}
}

func TestConfigOptionsFromACPKeepsValidDescriptorsOnly(t *testing.T) {
	options := configOptionsFromACP([]schema.SessionConfigOption{
		{
			ID:      "model",
			Type:    schema.SessionConfigOptionTypeSelect,
			Name:    "Model",
			Options: []schema.SessionConfigSelectOption{{Value: schema.SessionConfigValueId("fast"), Name: "Fast"}},
		},
		{ID: "bad-boolean", Type: schema.SessionConfigOptionTypeBoolean, CurrentValue: "true"},
		{ID: "auto-approve", Type: schema.SessionConfigOptionTypeBoolean, Name: "Auto approve", CurrentValue: false},
		{ID: "bad-select", Type: schema.SessionConfigOptionTypeSelect, CurrentValue: false},
		{ID: "unknown", Type: "future", CurrentValue: "value"},
	})
	// A select without a current value is kept; malformed descriptors are skipped.
	if len(options) != 2 || options[0].ID != "model" || options[0].CurrentValue != "" || len(options[0].Choices) != 1 {
		t.Fatalf("options = %#v, want the select kept with empty current value", options)
	}
	if options[1].ID != "auto-approve" || options[1].Type != provider.ConfigOptionTypeBoolean || options[1].CurrentValue != false {
		t.Fatalf("options = %#v, want the well-formed boolean kept", options)
	}
}

func TestSetSessionConfigOptionRejectsNonACPValue(t *testing.T) {
	instance := newInstance(provider.Host{})
	err := instance.setSessionConfigOptionValue(context.Background(), "session", "option", []string{"value"})
	if err == nil {
		t.Fatal("non-ACP config value was accepted")
	}
}

func TestSetBooleanConfigOptionSendsBooleanType(t *testing.T) {
	booleanOption := func(current bool) []any {
		return []any{map[string]any{"type": "boolean", "id": "auto-approve", "name": "Auto approve", "currentValue": current}}
	}
	sets := make(chan wireSessionParams, 1)
	agent := &fakeWireAgent{
		capabilities: map[string]any{"sessionCapabilities": map[string]any{"close": map[string]any{}}},
		onNewSession: func(agent *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			agent.respond(id, map[string]any{"sessionId": "options-session", "configOptions": booleanOption(false)})
		},
		onSetConfigOption: func(agent *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			sets <- params
			agent.respond(id, map[string]any{"configOptions": booleanOption(true)})
		},
	}
	instance := newWireTestHandle(t, agent)
	opened, err := instance.OpenOptions(context.Background(), "/tmp/project", provider.OptionsSessionCallbacks{})
	if err != nil {
		t.Fatalf("OpenOptionsSession: %v", err)
	}
	if len(opened.ConfigOptions) != 1 || opened.ConfigOptions[0].CurrentValue != false {
		t.Fatalf("opened options = %#v, want auto-approve=false", opened.ConfigOptions)
	}

	options, err := instance.SetOption(context.Background(), opened.Handle, "auto-approve", true)
	if err != nil {
		t.Fatalf("SetOptionsSessionValue: %v", err)
	}
	if params := waitFor(t, sets, "set_config_option was not sent"); params.Type != "boolean" || params.Value != true {
		t.Fatalf("set params = %#v, want type boolean value true", params)
	}
	if len(options) != 1 || options[0].CurrentValue != true {
		t.Fatalf("options = %#v, want auto-approve=true", options)
	}
}

func TestDisposableOptionsSessionStaysUnboundAndPublishesSpontaneousUpdates(t *testing.T) {
	wireOptions := func(current string) []any {
		return []any{map[string]any{
			"type": "select", "id": "model", "name": "Model",
			"category": "model", "currentValue": current,
			"options": []any{map[string]any{"value": "fast", "name": "Fast"}, map[string]any{"value": "slow", "name": "Slow"}},
		}}
	}
	agent := &fakeWireAgent{
		capabilities: map[string]any{"sessionCapabilities": map[string]any{"close": map[string]any{}}},
		onNewSession: func(agent *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			agent.respond(id, map[string]any{"sessionId": "options-session", "configOptions": wireOptions("fast")})
		},
		onSetConfigOption: func(agent *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			agent.respond(id, map[string]any{"configOptions": wireOptions("slow")})
		},
	}
	instance := newWireTestHandle(t, agent)
	updates := make(chan []provider.ConfigOption, 1)

	opened, err := instance.OpenOptions(context.Background(), "/tmp/project", provider.OptionsSessionCallbacks{
		Updated: func(options []provider.ConfigOption) { updates <- options },
	})
	if err != nil {
		t.Fatalf("OpenOptionsSession: %v", err)
	}
	if opened.Handle != "options-session" || len(opened.ConfigOptions) != 1 {
		t.Fatalf("opened = %#v, want one live option", opened)
	}

	options, err := instance.SetOption(context.Background(), opened.Handle, "model", "slow")
	if err != nil {
		t.Fatalf("SetOptionsSessionValue: %v", err)
	}
	if len(options) != 1 || options[0].CurrentValue != "slow" {
		t.Fatalf("options = %#v, want model=slow", options)
	}
	select {
	case update := <-updates:
		t.Fatalf("set response also published a duplicate update: %#v", update)
	default:
	}

	agent.sendUpdate("options-session", map[string]any{
		"sessionUpdate": "config_option_update",
		"configOptions": wireOptions("fast"),
	})
	update := waitFor(t, updates, "spontaneous options update was not published")
	if len(update) != 1 || update[0].CurrentValue != "fast" {
		t.Fatalf("update = %#v, want model=fast", update)
	}

	if err := instance.CloseOptions(context.Background(), opened.Handle); err != nil {
		t.Fatalf("CloseOptionsSession: %v", err)
	}
	if instance.sessionLockedForTest(opened.Handle) {
		t.Fatal("closed options session remained registered")
	}
}

func TestDisposableOptionsSessionsDoNotShareEmptyThreadBinding(t *testing.T) {
	agent := &fakeWireAgent{
		capabilities: map[string]any{"sessionCapabilities": map[string]any{"close": map[string]any{}}},
		onNewSession: func(agent *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			agent.respond(id, map[string]any{"sessionId": "options-" + params.Cwd})
		},
	}
	instance := newWireTestHandle(t, agent)

	first, err := instance.OpenOptions(context.Background(), "/first", provider.OptionsSessionCallbacks{})
	if err != nil {
		t.Fatalf("open first options session: %v", err)
	}
	second, err := instance.OpenOptions(context.Background(), "/second", provider.OptionsSessionCallbacks{})
	if err != nil {
		t.Fatalf("open second options session: %v", err)
	}
	if !instance.sessionLockedForTest(first.Handle) || !instance.sessionLockedForTest(second.Handle) {
		t.Fatalf("options sessions were not independently registered: first=%q second=%q", first.Handle, second.Handle)
	}

	if err := instance.CloseOptions(context.Background(), first.Handle); err != nil {
		t.Fatalf("close first options session: %v", err)
	}
	third, err := instance.OpenOptions(context.Background(), "/third", provider.OptionsSessionCallbacks{})
	if err != nil {
		t.Fatalf("open replacement options session: %v", err)
	}
	if !instance.sessionLockedForTest(second.Handle) || !instance.sessionLockedForTest(third.Handle) {
		t.Fatalf("closing one options session affected another: second=%q third=%q", second.Handle, third.Handle)
	}
}

func (h *Instance) sessionLockedForTest(sessionID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.sessions[sessionID] != nil
}

// claude-acp can switch modes with only current_mode_update while exposing the
// mode as a config option; the option must follow, or the picker goes stale.
func TestCurrentModeUpdateMovesModeConfigOption(t *testing.T) {
	mode := "mode"
	agent := &fakeWireAgent{onNewSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
		a.respond(id, map[string]any{"sessionId": "sess", "configOptions": []any{map[string]any{
			"type": "select", "id": "mode", "name": "Mode", "category": mode, "currentValue": "auto",
			"options": []any{map[string]any{"value": "auto", "name": "Auto"}, map[string]any{"value": "acceptEdits", "name": "Accept edits"}},
		}}})
	}}
	h := newWireTestHandle(t, agent)
	openSession(t, h, provider.OpenInput{})
	agent.sendUpdate("sess", map[string]any{"sessionUpdate": "current_mode_update", "currentModeId": "acceptEdits"})
	changed := h.events.WaitFor(t, "the options", func(event provider.Event) bool {
		changed, ok := event.Body.(provider.ConfigChanged)
		return ok && changed.Options != nil
	}).Body.(provider.ConfigChanged)
	if current, _ := provider.CurrentConfigString(changed.Options, "mode"); current != "acceptEdits" {
		t.Fatalf("mode option = %q, want acceptEdits", current)
	}
}
