package provider

import (
	"encoding/json"
	"testing"
)

func TestSessionEmptyListsMarshalExplicitArrays(t *testing.T) {
	session := Session{
		Provider:           DriverKind("acp"),
		ProviderInstanceID: "codex",
		ThreadID:           "thread-1",
		ConfigOptions:      []ConfigOption{},
	}

	raw, err := json.Marshal(session)
	if err != nil {
		t.Fatalf("marshal session: %v", err)
	}
	var payload map[string]json.RawMessage
	if err := json.Unmarshal(raw, &payload); err != nil {
		t.Fatalf("unmarshal session: %v", err)
	}
	if string(payload["configOptions"]) != "[]" {
		t.Fatalf("session JSON = %s, want configOptions:[]", raw)
	}
}
