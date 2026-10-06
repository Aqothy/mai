package acp

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/provider"
)

func TestInitializeOmitsUnstableBooleanCapability(t *testing.T) {
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
	request := waitFor(t, initializeRequests, "initialize request was not observed")
	if request.ClientCapabilities != nil {
		t.Fatalf("client capabilities = %#v, want stable-only capabilities omitted", request.ClientCapabilities)
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
		{ID: "unsupported-boolean", Type: schema.SessionConfigOptionTypeBoolean, CurrentValue: true},
		{ID: "bad-select", Type: schema.SessionConfigOptionTypeSelect, CurrentValue: false},
		{ID: "unknown", Type: "future", CurrentValue: "value"},
	})
	// A select without a current value is kept; malformed descriptors are skipped.
	if len(options) != 1 || options[0].ID != "model" || options[0].CurrentValue != "" || len(options[0].Choices) != 1 {
		t.Fatalf("options = %#v, want only the select kept with empty current value", options)
	}
}

func TestSetSessionConfigOptionRejectsNonACPValue(t *testing.T) {
	instance := newInstance(nil)
	err := instance.setSessionConfigOptionValue(context.Background(), "session", "option", []string{"value"})
	if err == nil {
		t.Fatal("non-ACP config value was accepted")
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

	opened, err := instance.OpenOptionsSession(context.Background(), "/tmp/project", provider.OptionsSessionCallbacks{
		Updated: func(options []provider.ConfigOption) { updates <- options },
	})
	if err != nil {
		t.Fatalf("OpenOptionsSession: %v", err)
	}
	if opened.Handle != "options-session" || len(opened.ConfigOptions) != 1 {
		t.Fatalf("opened = %#v, want one live option", opened)
	}
	if threadID := instance.threadIDForSession(opened.Handle); threadID != "" {
		t.Fatalf("options session bound to thread %q", threadID)
	}

	options, err := instance.SetOptionsSessionValue(context.Background(), opened.Handle, "model", "slow")
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

	if err := instance.CloseOptionsSession(context.Background(), opened.Handle); err != nil {
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

	first, err := instance.OpenOptionsSession(context.Background(), "/first", provider.OptionsSessionCallbacks{})
	if err != nil {
		t.Fatalf("open first options session: %v", err)
	}
	second, err := instance.OpenOptionsSession(context.Background(), "/second", provider.OptionsSessionCallbacks{})
	if err != nil {
		t.Fatalf("open second options session: %v", err)
	}
	if !instance.sessionLockedForTest(first.Handle) || !instance.sessionLockedForTest(second.Handle) {
		t.Fatalf("options sessions were not independently registered: first=%q second=%q", first.Handle, second.Handle)
	}

	if err := instance.CloseOptionsSession(context.Background(), first.Handle); err != nil {
		t.Fatalf("close first options session: %v", err)
	}
	third, err := instance.OpenOptionsSession(context.Background(), "/third", provider.OptionsSessionCallbacks{})
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
	return h.sessionLocked(sessionID) != nil
}
