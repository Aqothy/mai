package ipc

import (
	"encoding/json"
	"testing"
)

func TestNewRequestWithoutParams(t *testing.T) {
	req, err := NewRequest(ActionAgentInit, nil)
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	if req.Action != ActionAgentInit {
		t.Fatalf("action = %q, want %q", req.Action, ActionAgentInit)
	}
	if req.Params != nil {
		t.Fatalf("params = %s, want nil", req.Params)
	}
}

func TestNewRequestAndDecodeParams(t *testing.T) {
	want := AgentInitParams{Command: []string{"npx", "@zed-industries/codex-acp"}}
	req, err := NewRequest(ActionAgentInit, want)
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	if !json.Valid(req.Params) {
		t.Fatalf("params are not valid json: %s", req.Params)
	}

	var got AgentInitParams
	if err := req.DecodeParams(&got); err != nil {
		t.Fatalf("DecodeParams: %v", err)
	}
	if len(got.Command) != len(want.Command) {
		t.Fatalf("decoded params = %#v, want %#v", got, want)
	}
	for i := range want.Command {
		if got.Command[i] != want.Command[i] {
			t.Fatalf("command[%d] = %q, want %q", i, got.Command[i], want.Command[i])
		}
	}
}

func TestDecodeParamsInvalidJSON(t *testing.T) {
	req := Request{Action: ActionAgentInit, Params: []byte(`{"command":`)}
	var params AgentInitParams
	if err := req.DecodeParams(&params); err == nil {
		t.Fatal("DecodeParams succeeded, want error")
	}
}
