package acp

import (
	"encoding/json"
	"testing"

	"github.com/Aqothy/maiD/internal/provider"
)

// Every item event must carry the COMPLETE neutral tool-call snapshot, so
// sparse ACP tool_call_updates are accumulated adapter-side.
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

func TestToolCallFromACPDataNormalizesDisplayFields(t *testing.T) {
	data := json.RawMessage(`{
		"kind":"execute",
		"content":[
			{"type":"content","content":{"type":"text","text":"building"}},
			{"type":"content","content":{"type":"image","data":"aW1hZ2U=","mimeType":"image/png"}},
			{"type":"diff","path":"main.go","oldText":"old","newText":"new"},
			{"type":"terminal","terminalId":"term-1"}
		],
		"locations":[{"path":"main.go","line":12}],
		"rawInput":{"executable":"go","args":["test","./..."],"cwd":"/repo"},
		"rawOutput":{"content":"ok","exitCode":0,"durationMs":42}
	}`)

	call := toolCallFromACPData(data)
	if call == nil {
		t.Fatal("tool call is nil")
	}
	if call.Action != provider.ToolActionExecute || call.ProviderKind != "execute" || call.Command != "go test ./..." || call.Cwd != "/repo" {
		t.Fatalf("identity/input = %#v", call)
	}
	if len(call.Locations) != 1 || call.Locations[0].Path != "main.go" || call.Locations[0].Line == nil || *call.Locations[0].Line != 12 {
		t.Fatalf("locations = %#v", call.Locations)
	}
	if len(call.Changes) != 1 || call.Changes[0].Path != "main.go" || call.Changes[0].OldText != "old" || call.Changes[0].NewText != "new" {
		t.Fatalf("changes = %#v", call.Changes)
	}
	if len(call.Attachments) != 1 || call.Attachments[0].Kind != "image" {
		t.Fatalf("attachments = %#v", call.Attachments)
	}
	if call.Output != "building" || call.ExitCode != nil || call.DurationMilliseconds != nil {
		t.Fatalf("result = %#v", call)
	}
	if string(call.RawInput) != `{"executable":"go","args":["test","./..."],"cwd":"/repo"}` {
		t.Fatalf("raw input = %s", call.RawInput)
	}
}

func TestToolCallFromACPDataNormalizesQuery(t *testing.T) {
	call := toolCallFromACPData(json.RawMessage(`{"kind":"search","rawInput":{"query":"needle"}}`))
	if call == nil || call.Action != provider.ToolActionSearch || call.Query != "needle" {
		t.Fatalf("tool call = %#v", call)
	}
}

func TestToolCallFromACPDataPreservesExplicitEmptyCollections(t *testing.T) {
	call := toolCallFromACPData(json.RawMessage(`{"content":[],"locations":[]}`))
	if call == nil {
		t.Fatal("tool call is nil")
	}
	if call.Action != provider.ToolActionOther {
		t.Fatalf("action = %q, want %q", call.Action, provider.ToolActionOther)
	}
	if call.Attachments == nil || len(call.Attachments) != 0 {
		t.Fatalf("attachments = %#v, want explicit empty", call.Attachments)
	}
	if call.Changes == nil || len(call.Changes) != 0 {
		t.Fatalf("changes = %#v, want explicit empty", call.Changes)
	}
	if call.Locations == nil || len(call.Locations) != 0 {
		t.Fatalf("locations = %#v, want explicit empty", call.Locations)
	}
}
