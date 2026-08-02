package acp

import (
	"encoding/json"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/provider"
)

// decodeSessionUpdate mirrors the transport: SessionUpdate fields such as
// Content and RawInput arrive generically decoded, exactly as production
// hands them to toolCallPatchFromUpdate.
func decodeSessionUpdate(t *testing.T, raw string) schema.SessionUpdate {
	t.Helper()
	var update schema.SessionUpdate
	if err := json.Unmarshal([]byte(raw), &update); err != nil {
		t.Fatalf("decode session update: %v (%s)", err, raw)
	}
	return update
}

func TestToolCallPatchNormalizesRawInputAndRawOutput(t *testing.T) {
	patch := toolCallPatchFromUpdate(decodeSessionUpdate(t, `{
		"sessionUpdate":"tool_call_update",
		"toolCallId":"tool-1",
		"rawInput":{"command":"go test ./..."},
		"rawOutput":{"stdout":"ok  \tmaiD\t0.3s"}
	}`))
	if patch == nil || patch.rawInput == nil {
		t.Fatal("adapter-private rawInput missing; command normalization needs it")
	}
	call := patch.toolCall()
	if call == nil || call.Command != "go test ./..." {
		t.Fatalf("tool call = %#v, want normalized command", call)
	}
	if call.Output != "ok  \tmaiD\t0.3s" {
		t.Fatalf("output = %q, want rawOutput stdout backfilled", call.Output)
	}
}

// Textual content blocks are the canonical output; rawOutput only backfills
// when the agent sent none (e.g. command output without terminal support).
func TestToolCallOutputPrefersContentOverRawOutput(t *testing.T) {
	patch := toolCallPatchFromUpdate(decodeSessionUpdate(t, `{
		"sessionUpdate":"tool_call_update",
		"toolCallId":"tool-1",
		"content":[{"type":"content","content":{"type":"text","text":"from content"}}],
		"rawOutput":{"output":"from raw"}
	}`))
	if call := patch.toolCall(); call == nil || call.Output != "from content" {
		t.Fatalf("output = %#v, want content text preferred", call)
	}
}

func TestRawOutputTextRecognizesCommonShapes(t *testing.T) {
	cases := []struct {
		name string
		raw  any
		want string
	}{
		{name: "bare string", raw: "plain", want: "plain"},
		{name: "output field", raw: map[string]any{"output": "out"}, want: "out"},
		{
			name: "stdout with stderr",
			raw:  map[string]any{"stdout": "so", "stderr": "se"},
			want: "so\nse",
		},
		{
			name: "preserves whitespace",
			raw:  map[string]any{"stdout": "  indented\n", "stderr": "warning\n"},
			want: "  indented\nwarning\n",
		},
		{
			name: "adds separator only when needed",
			raw:  map[string]any{"stdout": "output", "stderr": "warning"},
			want: "output\nwarning",
		},
		{name: "stderr only", raw: map[string]any{"stderr": "boom"}, want: "boom"},
		{name: "text field", raw: map[string]any{"text": "t"}, want: "t"},
		{name: "unrecognized", raw: map[string]any{"blob": 42}, want: ""},
		{name: "nil", raw: nil, want: ""},
	}
	for _, tc := range cases {
		if got := rawOutputText(tc.raw); got != tc.want {
			t.Errorf("%s: rawOutputText = %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestBoundedOutputTextTruncatesOnRuneBoundary(t *testing.T) {
	long := strings.Repeat("é", toolOutputCharacterLimit)
	got := boundedOutputText(long)
	if len(got) > toolOutputCharacterLimit {
		t.Fatalf("retained %d bytes, want at most %d", len(got), toolOutputCharacterLimit)
	}
	if !utf8.ValidString(got) {
		t.Fatal("truncation split a rune")
	}
}

// Output is bounded no matter which source it came from.
func TestToolCallOutputFromContentIsBounded(t *testing.T) {
	oversized := strings.Repeat("x", toolOutputCharacterLimit+100)
	patch := &toolCallPatch{
		content: []schema.ToolCallContent{{
			Type: schema.ToolCallContentTypeContent,
			Content: &schema.ContentBlock{
				Type: schema.ContentBlockTypeText,
				Text: &oversized,
			},
		}},
	}
	if call := patch.toolCall(); len(call.Output) != toolOutputCharacterLimit {
		t.Fatalf("output length = %d, want bounded to %d", len(call.Output), toolOutputCharacterLimit)
	}
}

// Every item event must carry the COMPLETE neutral tool-call snapshot, so
// sparse ACP tool_call_updates are accumulated adapter-side.
func TestToolCallPatchOverlayAccumulatesSparseUpdates(t *testing.T) {
	start := toolCallPatchFromUpdate(decodeSessionUpdate(t, `{
		"sessionUpdate":"tool_call",
		"toolCallId":"tool-1",
		"title":"run tests",
		"status":"pending",
		"rawInput":{"command":"go test"}
	}`))
	update := toolCallPatchFromUpdate(decodeSessionUpdate(t, `{
		"sessionUpdate":"tool_call_update",
		"toolCallId":"tool-1",
		"status":"completed",
		"content":[]
	}`))

	merged := start.overlay(update)
	if merged.status == nil || *merged.status != schema.ToolCallStatusCompleted {
		t.Fatalf("merged status = %#v, want update fields applied", merged.status)
	}
	if merged.content == nil || len(merged.content) != 0 {
		t.Fatalf("merged content = %#v, want explicit empty replacement", merged.content)
	}
	if merged.title == nil || *merged.title != "run tests" {
		t.Fatalf("merged title = %#v, want fields from earlier updates preserved", merged.title)
	}
	call := merged.toolCall()
	if call == nil || call.Command != "go test" {
		t.Fatalf("tool call = %#v, want rawInput from earlier updates preserved", call)
	}

	if out := (*toolCallPatch)(nil).overlay(update); out != update {
		t.Fatalf("overlay with no base = %#v, want the update itself", out)
	}
	if out := start.overlay(nil); out != start {
		t.Fatalf("overlay with no patch = %#v, want the base kept", out)
	}
}

func TestToolCallPatchNormalizesDisplayFields(t *testing.T) {
	patch := toolCallPatchFromUpdate(decodeSessionUpdate(t, `{
		"sessionUpdate":"tool_call",
		"toolCallId":"tool-1",
		"kind":"execute",
		"content":[
			{"type":"content","content":{"type":"text","text":"building"}},
			{"type":"content","content":{"type":"image","data":"aW1hZ2U=","mimeType":"image/png"}},
			{"type":"diff","path":"main.go","oldText":"old","newText":"new"},
			{"type":"terminal","terminalId":"term-1"}
		],
		"locations":[{"path":"main.go","line":12}],
		"rawInput":{"executable":"go","args":["test","./..."],"cwd":"/repo"}
	}`))

	call := patch.toolCall()
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
}

func TestToolCallPatchNormalizesQuery(t *testing.T) {
	patch := toolCallPatchFromUpdate(decodeSessionUpdate(t, `{
		"sessionUpdate":"tool_call",
		"toolCallId":"tool-1",
		"kind":"search",
		"rawInput":{"query":"needle"}
	}`))
	call := patch.toolCall()
	if call == nil || call.Action != provider.ToolActionSearch || call.Query != "needle" {
		t.Fatalf("tool call = %#v", call)
	}
}

func TestToolCallPatchPreservesExplicitEmptyCollections(t *testing.T) {
	patch := toolCallPatchFromUpdate(decodeSessionUpdate(t, `{
		"sessionUpdate":"tool_call_update",
		"toolCallId":"tool-1",
		"content":[],
		"locations":[]
	}`))
	call := patch.toolCall()
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

func TestToolCallPatchFromNonToolUpdateIsNil(t *testing.T) {
	if patch := toolCallPatchFromUpdate(decodeSessionUpdate(t, `{
		"sessionUpdate":"agent_message_chunk",
		"content":{"type":"text","text":"hello"}
	}`)); patch != nil {
		t.Fatalf("patch = %#v, want nil for non-tool updates", patch)
	}
}
