package claudecode

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/Aqothy/maiD/internal/adapters/elicitation"
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
			// Create or update is known only from the result.
			return len(state.call.Changes) == 1 && state.call.Changes[0].Kind == "" && state.call.Changes[0].NewText == "data"
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

// File edits take the patch the CLI applied from the tool's structured
// result: line-numbered hunks for an edit, and an added file for a Write that
// created one.
func TestApplyResultUsesTheAppliedPatch(t *testing.T) {
	edit := newToolState("Edit", json.RawMessage(`{"file_path":"/tmp/a.go","old_string":"x","new_string":"y"}`))
	status := edit.applyResult(contentBlock{Type: "tool_result", Content: json.RawMessage(`"ok"`)}, json.RawMessage(`{"structuredPatch":[{"oldStart":12,"oldLines":1,"newStart":12,"newLines":1,"lines":["-x","+y"]}]}`))
	if status != provider.ItemStatusCompleted || edit.call.Changes[0] != (provider.FileChange{Path: "/tmp/a.go", Kind: provider.FileChangeUpdate, Diff: "@@ -12,1 +12,1 @@\n-x\n+y\n"}) {
		t.Fatalf("edit = %v %#v", status, edit.call.Changes[0])
	}
	write := newToolState("Write", json.RawMessage(`{"file_path":"/tmp/b.go","content":"data\n"}`))
	write.applyResult(contentBlock{Type: "tool_result"}, json.RawMessage(`{"type":"create","content":"data\n","structuredPatch":[]}`))
	if change := write.call.Changes[0]; change.Kind != provider.FileChangeAdd || change.Diff != "@@ -0,0 +1,1 @@\n+data\n" {
		t.Fatalf("write = %#v", change)
	}
	failed := newToolState("Edit", json.RawMessage(`{"file_path":"/tmp/a.go","old_string":"x","new_string":"y"}`))
	if status := failed.applyResult(contentBlock{Type: "tool_result", IsError: true, Content: json.RawMessage(`"no match"`)}, nil); status != provider.ItemStatusFailed || failed.call.Error != "no match" || failed.call.Changes[0].Diff != "" {
		t.Fatalf("failed edit = %v %#v", status, failed.call)
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
	// Plain success and aborted (interrupted) results are covered by the
	// fake-CLI turns. Running out of turns or tokens completes the turn early.
	state, reason, _ := turnStateFromResult(resultMessage{Subtype: "error_max_turns", IsError: true})
	if state != provider.TurnCompleted || reason != provider.StopReasonMaxTurnRequests {
		t.Fatalf("max turns = %q %q, want completed early at the request limit", state, reason)
	}
	state, reason, _ = turnStateFromResult(resultMessage{Subtype: "success", StopReason: "max_tokens"})
	if state != provider.TurnCompleted || reason != provider.StopReasonMaxTokens {
		t.Fatalf("max tokens = %q %q, want completed early at the output limit", state, reason)
	}
	var message string
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
		// A subagent on another model must not set the session's window.
		ModelUsage: map[string]modelUsage{"claude-x": {ContextWindow: 200000}, "claude-sub": {ContextWindow: 1000000}},
	}, "claude-x")
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
	blocks, err := userContentBlocks("hello", []provider.Attachment{{Kind: "image", MimeType: "image/png", Data: "Zm9v"}})
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
	if _, err := userContentBlocks("", nil); err == nil {
		t.Fatal("empty turn should error")
	}
	if _, err := userContentBlocks("", []provider.Attachment{{Kind: "audio", Data: "x"}}); err == nil {
		t.Fatal("audio attachment should error")
	}
	// data URLs are unwrapped into raw base64 for the API block.
	blocks, err = userContentBlocks("", []provider.Attachment{{Kind: "image", Data: "data:image/jpeg;base64,YWJj"}})
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
		input:       json.RawMessage(`{"command":"echo hi"}`),
		suggestions: []json.RawMessage{json.RawMessage(`{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"echo *"}],"behavior":"allow","destination":"localSettings"}`)},
	}
	payload := permissionResponse(pending, "accept")
	if payload["behavior"] != "allow" {
		t.Fatalf("accept payload = %#v", payload)
	}
	payload = permissionResponse(pending, "acceptForSession")
	updates := payload["updatedPermissions"].([]map[string]any)
	if len(updates) != 1 || updates[0]["destination"] != "session" {
		t.Fatalf("updates = %#v, want session destination (never persisted to settings files)", updates)
	}
	payload = permissionResponse(pending, "decline")
	if payload["behavior"] != "deny" || payload["interrupt"] == true {
		t.Fatalf("decline payload = %#v", payload)
	}
	payload = permissionResponse(pending, "cancel")
	if payload["interrupt"] != true {
		t.Fatalf("cancel payload = %#v", payload)
	}

	// Without CLI suggestions there is no rule to approve: the CLI ignores a
	// made-up whole-tool rule, so none is sent.
	payload = permissionResponse(&pendingApproval{input: json.RawMessage(`{}`)}, "acceptForSession")
	if updates := payload["updatedPermissions"].([]map[string]any); len(updates) != 0 {
		t.Fatalf("updates = %#v, want none", updates)
	}
}

// AskUserQuestion answers go back in updatedInput.answers keyed by question
// text; several selections join with ", " and a typed answer replaces the
// options. A missing answer is reported instead of sent.
func TestAskUserQuestionAnswers(t *testing.T) {
	input := json.RawMessage(`{"questions":[
		{"question":"Which one?","header":"Pick","options":[{"label":"A"},{"label":"B"}]},
		{"question":"Which tools?","header":"Tools","multiSelect":true,"options":[{"label":"git"},{"label":"make"}]}
	]}`)
	var question askUserQuestion
	if err := json.Unmarshal(input, &question); err != nil {
		t.Fatal(err)
	}
	pending := &pendingApproval{input: input, question: &question}
	respond := func(answers map[string][]string) (map[string]any, error) {
		return approvalResponse(pending, provider.RequestAnswer{Action: question.request().Actions[0], Answers: answers})
	}
	if _, err := respond(map[string][]string{"Which one?": {"B"}}); err == nil {
		t.Fatal("an unanswered question was sent")
	}
	payload, err := respond(map[string][]string{"Which one?": {"something else"}, "Which tools?": {"git", "make"}})
	if err != nil || payload["behavior"] != "allow" {
		t.Fatalf("payload = %#v, %v", payload, err)
	}
	answers := payload["updatedInput"].(map[string]any)["answers"].(map[string]string)
	if answers["Which one?"] != "something else" || answers["Which tools?"] != "git, make" {
		t.Fatalf("answers = %#v", answers)
	}
}

// ExitPlanMode's review approves the plan, or keeps planning and hands the
// user's typed feedback, if any, to the model as the deny message.
func TestPlanReviewResponse(t *testing.T) {
	pending := &pendingApproval{input: json.RawMessage(`{"plan":"Do it"}`), reviewsPlan: true}
	review := planReviewRequest(pending.input)
	tests := []struct {
		name     string
		action   string
		feedback []string
		want     map[string]any
	}{
		{"approve", planApprove, nil, map[string]any{"behavior": "allow", "updatedInput": json.RawMessage(`{"plan":"Do it"}`)}},
		{"keep planning", planKeepPlanning, nil, map[string]any{"behavior": "deny", "message": "The user wants to keep planning."}},
		{"feedback", planKeepPlanning, []string{"Add tests first"}, map[string]any{"behavior": "deny", "message": "The user wants to keep planning. Their feedback on the plan: Add tests first"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			action, ok := review.Action(tt.action)
			if !ok {
				t.Fatalf("the review offers no %q action", tt.action)
			}
			payload, err := approvalResponse(pending, provider.RequestAnswer{Action: action, Answers: map[string][]string{planFeedbackQuestionID: tt.feedback}})
			if err != nil || !reflect.DeepEqual(payload, tt.want) {
				t.Fatalf("payload = %#v, err = %v; want %#v", payload, err, tt.want)
			}
		})
	}
}

// An MCP server's elicitation is answered with the SDK's {action, content}.
func TestElicitationResponse(t *testing.T) {
	request, form, err := elicitation.Parse("Name?", "", "", json.RawMessage(`{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}`))
	if err != nil {
		t.Fatal(err)
	}
	pending := &pendingApproval{isElicitation: true, form: form}
	respond := func(actionID string, answers map[string][]string) (map[string]any, error) {
		action, ok := request.Action(actionID)
		if !ok {
			t.Fatalf("the form offers no %q action", actionID)
		}
		return approvalResponse(pending, provider.RequestAnswer{Action: action, Answers: answers})
	}
	if _, err := respond("accept", nil); err == nil {
		t.Fatal("a missing required answer was sent")
	}
	payload, err := respond("accept", map[string][]string{"name": {"maiD"}})
	if err != nil || !reflect.DeepEqual(payload, map[string]any{"action": elicitation.ActionAccept, "content": map[string]any{"name": "maiD"}}) {
		t.Fatalf("payload = %#v, %v", payload, err)
	}
	if payload, _ := respond("decline", nil); payload["action"] != elicitation.ActionDecline {
		t.Fatalf("decline payload = %#v", payload)
	}
}

func TestMungeProjectPath(t *testing.T) {
	if got := sanitizePath("/private/tmp/claude-proto-test"); got != "-private-tmp-claude-proto-test" {
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
