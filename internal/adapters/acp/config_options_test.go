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
	requests := make(chan wireSessionParams, 1)
	agent := &fakeWireAgent{
		onNewSession: func(agent *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			agent.respond(id, map[string]any{"sessionId": "sess", "configOptions": wireBooleanOptions(false)})
		},
		onSetConfigOption: func(agent *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			requests <- params
			agent.respond(id, map[string]any{"configOptions": wireBooleanOptions(true)})
		},
	}
	instance := newWireTestHandle(t, agent)

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
