package acp

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/provider"
)

func TestSetConfigOptionSendsBooleanWireValue(t *testing.T) {
	wireBooleanOptions := func(current bool) []any {
		return []any{map[string]any{"type": "boolean", "id": "fast", "name": "Fast mode", "category": "model_config", "currentValue": current}}
	}
	initializeRequests := make(chan schema.InitializeRequest, 1)
	requests := make(chan wireSessionParams, 1)
	agent := &fakeWireAgent{
		onInitialize: func(params json.RawMessage) {
			var request schema.InitializeRequest
			if err := json.Unmarshal(params, &request); err != nil {
				t.Errorf("decode initialize request: %v", err)
				return
			}
			initializeRequests <- request
		},
		onNewSession: func(agent *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			agent.respond(id, map[string]any{"sessionId": "sess", "configOptions": wireBooleanOptions(false)})
		},
		onSetConfigOption: func(agent *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			requests <- params
			agent.respond(id, map[string]any{"configOptions": wireBooleanOptions(true)})
		},
	}
	instance := newWireTestHandle(t, agent)
	select {
	case request := <-initializeRequests:
		if request.ClientCapabilities == nil ||
			request.ClientCapabilities.Session == nil ||
			request.ClientCapabilities.Session.ConfigOptions == nil ||
			request.ClientCapabilities.Session.ConfigOptions.Boolean == nil {
			t.Fatalf("client capabilities = %#v, want session.configOptions.boolean", request.ClientCapabilities)
		}
	case <-time.After(time.Second):
		t.Fatal("initialize request was not observed")
	}

	result, err := instance.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1"})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if len(result.Session.ConfigOptions) != 1 {
		t.Fatalf("initial config options = %#v, want one boolean option", result.Session.ConfigOptions)
	}
	initial := result.Session.ConfigOptions[0]
	if initial.ID != "fast" || initial.Type != provider.ConfigOptionTypeBoolean || initial.Category != provider.ConfigOptionCategoryModelConfig || initial.CurrentValue != false || len(initial.Choices) != 0 {
		t.Fatalf("initial boolean option = %#v, want false model-config option without choices", initial)
	}
	if err := instance.SetConfigOption(context.Background(), provider.SetConfigOptionInput{ThreadID: "thread-1", OptionID: "fast", Value: true}); err != nil {
		t.Fatalf("SetConfigOption: %v", err)
	}
	select {
	case request := <-requests:
		if request.Type != schema.SetSessionConfigOptionRequestTypeBoolean || request.Value != true {
			t.Fatalf("wire request = %#v, want boolean type and value", request)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("session/set_config_option was not called")
	}
	options := instance.combinedConfigOptions("sess")
	if len(options) != 1 || options[0].CurrentValue != true {
		t.Fatalf("cached options = %#v, want fast=true", options)
	}
}

func TestConfigOptionsFromACPKeepsSelectWithoutCurrentValue(t *testing.T) {
	options := configOptionsFromACP([]schema.SessionConfigOption{{
		ID:      "model",
		Type:    schema.SessionConfigOptionTypeSelect,
		Name:    "Model",
		Options: []schema.SessionConfigSelectOption{{Value: schema.SessionConfigValueId("fast"), Name: "Fast"}},
	}})
	if len(options) != 1 || options[0].CurrentValue != "" || len(options[0].Choices) != 1 {
		t.Fatalf("options = %#v, want select kept with empty current value", options)
	}
}

func TestConfigOptionsFromACPSkipsMalformedValues(t *testing.T) {
	options := configOptionsFromACP([]schema.SessionConfigOption{
		{ID: "bad-boolean", Type: schema.SessionConfigOptionTypeBoolean, CurrentValue: "true"},
		{ID: "bad-select", Type: schema.SessionConfigOptionTypeSelect, CurrentValue: false},
		{ID: "unknown", Type: "future", CurrentValue: "value"},
	})
	if len(options) != 0 {
		t.Fatalf("options = %#v, want malformed descriptors skipped", options)
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
	select {
	case update := <-updates:
		if len(update) != 1 || update[0].CurrentValue != "fast" {
			t.Fatalf("update = %#v, want model=fast", update)
		}
	case <-time.After(time.Second):
		t.Fatal("spontaneous options update was not published")
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
