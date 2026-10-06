package claudecode

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/Aqothy/maiD/internal/provider"
)

func TestNewToolState(t *testing.T) {
	for _, tc := range []struct {
		name, tool, input string
		check             func(toolState) bool
	}{
		{"bash", "Bash", `{"command":"echo hi","description":"Print hi"}`, func(state toolState) bool {
			return state.itemKind == provider.ItemKindCommandExecution && state.call.Command == "echo hi" && state.title == "Print hi"
		}},
		{"edit", "Edit", `{"file_path":"/tmp/a.go","old_string":"x","new_string":"y"}`, func(state toolState) bool {
			return state.itemKind == provider.ItemKindFileChange && len(state.call.Changes) == 1 &&
				state.call.Changes[0] == provider.FileChange{Path: "/tmp/a.go", Kind: provider.FileChangeUpdate, OldText: "x", NewText: "y"}
		}},
		{"write", "Write", `{"file_path":"/tmp/b.go","content":"data"}`, func(state toolState) bool {
			return len(state.call.Changes) == 1 && state.call.Changes[0].Kind == provider.FileChangeAdd && state.call.Changes[0].NewText == "data"
		}},
		{"mcp", "mcp__github__list_issues", ``, func(state toolState) bool {
			return state.itemKind == provider.ItemKindMCPToolCall && state.call.Namespace == "github" && state.call.Name == "list_issues" && state.title == "github · list_issues"
		}},
		{"todo write is plan only", "TodoWrite", `{"todos":[]}`, func(state toolState) bool { return state.itemKind == "" }},
	} {
		var input json.RawMessage
		if tc.input != "" {
			input = json.RawMessage(tc.input)
		}
		if state := newToolState(tc.tool, input); !tc.check(*state) {
			t.Errorf("%s: newToolState(%q) = %#v", tc.name, tc.tool, state)
		}
	}
}

// Only built-ins whose own identity is a file read or search state an action;
// every other tool (MCP, unknown, or newer) leaves it empty.
func TestNewToolStateActions(t *testing.T) {
	for tool, want := range map[string]provider.ToolAction{
		"Read":                     provider.ToolActionRead,
		"Grep":                     provider.ToolActionSearch,
		"Glob":                     provider.ToolActionSearch,
		"Bash":                     "",
		"ReadMcpResourceTool":      "",
		"mcp__github__list_issues": "",
	} {
		if got := newToolState(tool, nil).call.Action; got != want {
			t.Errorf("newToolState(%q) action = %q, want %q", tool, got, want)
		}
	}
}

func TestPlanEntriesFromInput(t *testing.T) {
	entries := planEntriesFromInput(json.RawMessage(`{"todos":[{"content":"one","status":"completed"},{"content":"two","status":"in_progress"},{"content":"three","status":"pending"}]}`))
	if len(entries) != 3 {
		t.Fatalf("entries = %#v, want 3", entries)
	}
	if entries[0].Status != provider.PlanEntryStatusCompleted || entries[1].Status != provider.PlanEntryStatusInProgress || entries[2].Status != provider.PlanEntryStatusPending {
		t.Fatalf("statuses = %#v", entries)
	}
	if planEntriesFromInput(json.RawMessage(`{"other":true}`)) != nil {
		t.Fatal("non-todo input should produce no entries")
	}
}

func TestToolResultContent(t *testing.T) {
	text, attachments := toolResultContent(json.RawMessage(`"plain output"`))
	if text != "plain output" || attachments != nil {
		t.Fatalf("string content = %q %#v", text, attachments)
	}
	text, attachments = toolResultContent(json.RawMessage(`[{"type":"text","text":"a"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"Zm9v"}},{"type":"text","text":"b"}]`))
	if text != "a\nb" {
		t.Fatalf("text = %q, want joined", text)
	}
	if len(attachments) != 1 || attachments[0].MimeType != "image/png" || attachments[0].Data != "Zm9v" {
		t.Fatalf("attachments = %#v", attachments)
	}
}

func TestTurnStateFromResult(t *testing.T) {
	// Success and aborted (interrupted) results are covered by the fake-CLI turns.
	state, _, message := turnStateFromResult(resultMessage{Subtype: "error_max_turns", IsError: true})
	if state != provider.RuntimeTurnFailed || message != "max_turns" {
		t.Fatalf("max turns state = %q message = %q", state, message)
	}
	// Internal diagnostics must never surface as the error banner.
	_, _, message = turnStateFromResult(resultMessage{Subtype: "error_during_execution", IsError: true, Errors: []string{"[ede_diagnostic] noise", "real problem"}})
	if message != "real problem" {
		t.Fatalf("message = %q, want real problem", message)
	}
}

func TestTokenUsageFromResult(t *testing.T) {
	usage := tokenUsageFromResult(resultMessage{
		TotalCostUSD: 0.5,
		Usage:        json.RawMessage(`{"input_tokens":1,"cache_read_input_tokens":2,"cache_creation_input_tokens":3,"output_tokens":4,"iterations":[{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30,"output_tokens":40}]}`),
		ModelUsage:   map[string]modelUsage{"claude-x": {ContextWindow: 200000}},
	})
	if usage == nil {
		t.Fatal("usage = nil")
	}
	if usage.UsedTokens != 100 {
		t.Fatalf("UsedTokens = %d, want last iteration total 100", usage.UsedTokens)
	}
	if usage.MaxTokens != 200000 || usage.Cost != 0.5 || usage.Currency != "USD" {
		t.Fatalf("usage = %#v", usage)
	}
}

func TestUserContentBlocks(t *testing.T) {
	blocks, err := userContentBlocks(provider.SendTurnInput{Input: "hello", Attachments: []provider.Attachment{{Kind: "image", MimeType: "image/png", Data: "Zm9v"}}})
	if err != nil {
		t.Fatalf("userContentBlocks: %v", err)
	}
	if len(blocks) != 2 || blocks[0]["type"] != "text" || blocks[1]["type"] != "image" {
		t.Fatalf("blocks = %#v", blocks)
	}
	source := blocks[1]["source"].(map[string]any)
	if source["media_type"] != "image/png" || source["data"] != "Zm9v" {
		t.Fatalf("source = %#v", source)
	}
	if _, err := userContentBlocks(provider.SendTurnInput{}); err == nil {
		t.Fatal("empty turn should error")
	}
	if _, err := userContentBlocks(provider.SendTurnInput{Attachments: []provider.Attachment{{Kind: "audio", Data: "x"}}}); err == nil {
		t.Fatal("audio attachment should error")
	}
	// data URLs are unwrapped into raw base64 for the API block.
	blocks, err = userContentBlocks(provider.SendTurnInput{Attachments: []provider.Attachment{{Kind: "image", Data: "data:image/jpeg;base64,YWJj"}}})
	if err != nil {
		t.Fatalf("data url attachment: %v", err)
	}
	source = blocks[0]["source"].(map[string]any)
	if source["media_type"] != "image/jpeg" || source["data"] != "YWJj" {
		t.Fatalf("source = %#v", source)
	}
}

func TestPermissionResponseDecisions(t *testing.T) {
	pending := &pendingApproval{
		toolName:    "Bash",
		input:       json.RawMessage(`{"command":"echo hi"}`),
		suggestions: []json.RawMessage{json.RawMessage(`{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"echo *"}],"behavior":"allow","destination":"localSettings"}`)},
	}
	payload, decision := permissionResponse(pending, "accept")
	if decision != provider.ApprovalDecisionAccept || payload["behavior"] != "allow" {
		t.Fatalf("accept payload = %#v decision = %q", payload, decision)
	}
	payload, decision = permissionResponse(pending, "acceptForSession")
	if decision != provider.ApprovalDecisionAcceptForSession {
		t.Fatalf("decision = %q", decision)
	}
	updates := payload["updatedPermissions"].([]map[string]any)
	if len(updates) != 1 || updates[0]["destination"] != "session" {
		t.Fatalf("updates = %#v, want session destination (never persisted to settings files)", updates)
	}
	payload, decision = permissionResponse(pending, "decline")
	if decision != provider.ApprovalDecisionDecline || payload["behavior"] != "deny" {
		t.Fatalf("decline payload = %#v", payload)
	}
	payload, decision = permissionResponse(pending, "cancel")
	if decision != provider.ApprovalDecisionCancel || payload["interrupt"] != true {
		t.Fatalf("cancel payload = %#v", payload)
	}

	// Without CLI suggestions, session approval falls back to a tool rule.
	payload, _ = permissionResponse(&pendingApproval{toolName: "mcp__github__list_issues", input: json.RawMessage(`{}`)}, "acceptForSession")
	updates = payload["updatedPermissions"].([]map[string]any)
	if len(updates) != 1 || updates[0]["type"] != "addRules" || updates[0]["destination"] != "session" {
		t.Fatalf("updates = %#v, want session addRules fallback", updates)
	}
}

func TestPermissionResponseAskUserQuestion(t *testing.T) {
	input := json.RawMessage(`{"questions":[{"question":"Which one?","header":"Pick","options":[{"label":"A"},{"label":"B"}]}]}`)
	var question askUserQuestion
	if err := json.Unmarshal(input, &question); err != nil {
		t.Fatal(err)
	}
	pending := &pendingApproval{toolName: "AskUserQuestion", input: input, question: &question}
	payload, decision := permissionResponse(pending, "answer:1")
	if decision != provider.ApprovalDecisionAccept || payload["behavior"] != "allow" {
		t.Fatalf("payload = %#v", payload)
	}
	updated := payload["updatedInput"].(map[string]any)
	// Answers must key by the full question text (SDK looks answers up by it).
	answers := updated["answers"].(map[string]string)
	if answers["Which one?"] != "B" {
		t.Fatalf("answers = %#v", answers)
	}
}

func TestMungeProjectPath(t *testing.T) {
	if got := mungeProjectPath("/private/tmp/claude-proto-test"); got != "-private-tmp-claude-proto-test" {
		t.Fatalf("munge = %q", got)
	}
}

func TestBoundedOutputRespectsUTF8(t *testing.T) {
	value := strings.Repeat("é", toolOutputLimit)
	bounded := boundedOutput(value)
	if len(bounded) > toolOutputLimit {
		t.Fatalf("bounded length = %d", len(bounded))
	}
	if !strings.HasPrefix(value, bounded) {
		t.Fatal("bounded output is not a prefix")
	}
}
