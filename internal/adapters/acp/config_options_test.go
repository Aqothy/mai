package acp

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/provider"
)

func TestConfigOptionsFromACPIncludesBooleanOptions(t *testing.T) {
	category := schema.SessionConfigOptionCategoryModelConfig
	options := configOptionsFromACP([]schema.SessionConfigOption{{
		ID:           "fast",
		Type:         schema.SessionConfigOptionTypeBoolean,
		Name:         "Fast mode",
		Category:     &category,
		CurrentValue: true,
	}})
	if len(options) != 1 {
		t.Fatalf("options = %#v, want one boolean option", options)
	}
	option := options[0]
	if option.Type != provider.ConfigOptionTypeBoolean || option.Category != provider.ConfigOptionCategoryModelConfig || option.CurrentValue != true {
		t.Fatalf("option = %#v", option)
	}
	if len(option.Choices) != 0 {
		t.Fatalf("boolean choices = %#v, want none", option.Choices)
	}
}

func TestSetConfigOptionSendsBooleanWireValue(t *testing.T) {
	wireBooleanOptions := func(current bool) []any {
		return []any{map[string]any{"type": "boolean", "id": "fast", "name": "Fast mode", "currentValue": current}}
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

	if _, err := instance.StartSession(context.Background(), provider.StartSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StartSession: %v", err)
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
