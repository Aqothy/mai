package acp

import (
	"encoding/json"
	"testing"
)

// Every item event must carry the COMPLETE tool-call state (downstream item
// payloads are replacements, not merge-patches), so sparse ACP
// tool_call_updates are accumulated adapter-side.
func TestOverlayToolCallDataAccumulatesSparseUpdates(t *testing.T) {
	start := json.RawMessage(`{"toolCallId":"tool-1","title":"run tests","status":"pending","rawInput":{"command":"go test"}}`)
	update := json.RawMessage(`{"toolCallId":"tool-1","status":"completed","rawOutput":{"exit":0}}`)

	merged := overlayToolCallData(start, update)
	var got map[string]json.RawMessage
	if err := json.Unmarshal(merged, &got); err != nil {
		t.Fatalf("merged data unparseable: %v (%s)", err, merged)
	}
	if string(got["status"]) != `"completed"` || string(got["rawOutput"]) != `{"exit":0}` {
		t.Fatalf("merged = %s, want update fields applied", merged)
	}
	if string(got["title"]) != `"run tests"` || string(got["rawInput"]) != `{"command":"go test"}` {
		t.Fatalf("merged = %s, want fields from earlier updates preserved", merged)
	}

	if out := overlayToolCallData(nil, update); string(out) != string(update) {
		t.Fatalf("overlay with no base = %s, want the update itself", out)
	}
	if out := overlayToolCallData(start, nil); string(out) != string(start) {
		t.Fatalf("overlay with no patch = %s, want the base kept", out)
	}
}
