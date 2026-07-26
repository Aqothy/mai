package provider

import (
	"encoding/json"
	"testing"
)

func TestToolCallContractCoversTargetProviderShapes(t *testing.T) {
	exitZero := 0
	duration := int64(42)
	line := uint32(12)
	tests := []struct {
		name string
		call ToolCall
	}{
		{
			name: "ACP",
			call: ToolCall{
				Action:       ToolActionExecute,
				ProviderKind: "execute",
				Command:      "go test ./...",
				Cwd:          "/repo",
				Locations:    []ToolLocation{{Path: "main.go", Line: &line}},
				Changes:      []FileChange{{Path: "main.go", Kind: FileChangeUpdate, OldText: "old", NewText: "new"}},
				Attachments:  []Attachment{{Kind: "image", Data: "aW1hZ2U=", MimeType: "image/png"}},
				RawInput:     json.RawMessage(`{"command":"go test ./..."}`),
				RawOutput:    json.RawMessage(`{"exitCode":0}`),
				ExitCode:     &exitZero,
			},
		},
		{
			name: "Codex app-server",
			call: ToolCall{
				Action:       ToolActionSearch,
				Name:         "web_search",
				ProviderKind: "webSearch",
				Query:        "neutral tool contracts",
				RawInput:     json.RawMessage(`{"query":"neutral tool contracts"}`),
				RawOutput:    json.RawMessage(`{"results":[{"title":"Result"}]}`),
			},
		},
		{
			name: "Codex app-server MCP",
			call: ToolCall{
				Action:               ToolActionOther,
				Name:                 "preview_snapshot",
				Namespace:            "t3-code",
				ProviderKind:         "mcpToolCall",
				Output:               "snapshot ready",
				Attachments:          []Attachment{{Kind: "resource", URI: "file:///tmp/snapshot.png", MimeType: "image/png"}},
				RawInput:             json.RawMessage(`{"interactiveOnly":true}`),
				RawOutput:            json.RawMessage(`{"structuredContent":{"ok":true}}`),
				DurationMilliseconds: &duration,
			},
		},
		{
			name: "Claude Code",
			call: ToolCall{
				Action:       ToolActionEdit,
				Name:         "Edit",
				ProviderKind: "tool_use",
				Locations:    []ToolLocation{{Path: "/repo/main.go"}},
				Changes:      []FileChange{{Path: "/repo/main.go", Kind: FileChangeUpdate}},
				RawInput:     json.RawMessage(`{"file_path":"/repo/main.go","old_string":"old","new_string":"new"}`),
				RawOutput:    json.RawMessage(`{"type":"tool_result","content":"updated"}`),
				Output:       "updated",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			encoded, err := json.Marshal(test.call)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			var decoded ToolCall
			if err := json.Unmarshal(encoded, &decoded); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if decoded.Action != test.call.Action || decoded.Name != test.call.Name || decoded.ProviderKind != test.call.ProviderKind {
				t.Fatalf("identity fields changed: got %#v want %#v", decoded, test.call)
			}
			if string(decoded.RawInput) != string(test.call.RawInput) || string(decoded.RawOutput) != string(test.call.RawOutput) {
				t.Fatalf("raw values changed: got %s / %s", decoded.RawInput, decoded.RawOutput)
			}
			if len(decoded.Locations) != len(test.call.Locations) || len(decoded.Changes) != len(test.call.Changes) || len(decoded.Attachments) != len(test.call.Attachments) {
				t.Fatalf("display collections changed: got %#v want %#v", decoded, test.call)
			}
		})
	}
}
