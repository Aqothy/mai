package claudecode

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/Aqothy/maiD/internal/provider"
)

const toolOutputLimit = 32 * 1024

// toolInput is the union of the built-in tool input fields maiD projects.
type toolInput struct {
	Command      string `json:"command,omitempty"`
	Description  string `json:"description,omitempty"`
	FilePath     string `json:"file_path,omitempty"`
	NotebookPath string `json:"notebook_path,omitempty"`
	OldString    string `json:"old_string,omitempty"`
	NewString    string `json:"new_string,omitempty"`
	NewSource    string `json:"new_source,omitempty"`
	Content      string `json:"content,omitempty"`
	Pattern      string `json:"pattern,omitempty"`
	Path         string `json:"path,omitempty"`
	Query        string `json:"query,omitempty"`
	URL          string `json:"url,omitempty"`
	Plan         string `json:"plan,omitempty"`
	SubagentType string `json:"subagent_type,omitempty"`
	Skill        string `json:"skill,omitempty"`
	Offset       *int   `json:"offset,omitempty"`
}

// newToolState builds the complete display snapshot for one tool_use block.
// An empty itemKind marks plan-carrying tools (TodoWrite) that surface through
// turn.plan.updated instead of a timeline item.
func newToolState(name string, rawInput json.RawMessage) *toolState {
	var input toolInput
	if len(rawInput) > 0 {
		_ = json.Unmarshal(rawInput, &input)
	}
	state := &toolState{itemKind: provider.ItemKindToolCall}
	call := provider.ToolCall{Name: name, ProviderKind: name, Action: provider.ToolActionFromName(name)}
	title := provider.HumanizeIdentifier(name)

	if server, tool, ok := splitMCPToolName(name); ok {
		call.Name = tool
		call.Namespace = server
		call.Action = provider.ToolActionFromName(tool)
		state.itemKind = provider.ItemKindMCPToolCall
		state.call = call
		state.title = strings.Trim(server+" · "+provider.HumanizeIdentifier(tool), " ·")
		return state
	}

	switch name {
	case "Bash", "BashOutput", "KillShell":
		state.itemKind = provider.ItemKindCommandExecution
		call.Action = provider.ToolActionExecute
		call.Command = input.Command
		title = trimmedOrDefault(input.Description, "Ran command")
	case "Edit":
		state.itemKind = provider.ItemKindFileChange
		call.Action = provider.ToolActionEdit
		if input.FilePath != "" {
			call.Changes = []provider.FileChange{{Path: input.FilePath, Kind: provider.FileChangeUpdate, OldText: input.OldString, NewText: input.NewString}}
			call.Locations = []provider.ToolLocation{{Path: input.FilePath}}
		}
		title = "Edited file"
	case "Write":
		state.itemKind = provider.ItemKindFileChange
		call.Action = provider.ToolActionEdit
		if input.FilePath != "" {
			call.Changes = []provider.FileChange{{Path: input.FilePath, Kind: provider.FileChangeAdd, NewText: input.Content}}
			call.Locations = []provider.ToolLocation{{Path: input.FilePath}}
		}
		title = "Wrote file"
	case "NotebookEdit":
		state.itemKind = provider.ItemKindFileChange
		call.Action = provider.ToolActionEdit
		if input.NotebookPath != "" {
			call.Changes = []provider.FileChange{{Path: input.NotebookPath, Kind: provider.FileChangeUpdate, NewText: input.NewSource}}
			call.Locations = []provider.ToolLocation{{Path: input.NotebookPath}}
		}
		title = "Edited notebook"
	case "Read":
		call.Action = provider.ToolActionRead
		if input.FilePath != "" {
			location := provider.ToolLocation{Path: input.FilePath}
			if input.Offset != nil && *input.Offset > 0 {
				line := uint32(*input.Offset)
				location.Line = &line
			}
			call.Locations = []provider.ToolLocation{location}
		}
		title = "Read file"
	case "Glob", "Grep":
		call.Action = provider.ToolActionSearch
		call.Query = input.Pattern
		call.Cwd = input.Path
		title = "Searched files"
		if name == "Grep" {
			title = "Searched text"
		}
	case "WebSearch":
		state.itemKind = provider.ItemKindWebSearch
		call.Action = provider.ToolActionSearch
		call.Query = input.Query
		title = trimmedOrDefault(input.Query, "Searched the web")
	case "WebFetch":
		call.Action = provider.ToolActionFetch
		call.Query = input.URL
		title = trimmedOrDefault(input.URL, "Fetched URL")
	case "Task", "Agent":
		call.Action = provider.ToolActionDelegate
		call.Query = input.SubagentType
		title = trimmedOrDefault(input.Description, "Delegated to agent")
	case "Skill":
		call.Action = provider.ToolActionDelegate
		call.Query = firstNonEmpty(input.Skill, input.Command)
		title = trimmedOrDefault("Skill "+call.Query, "Ran skill")
	case "ExitPlanMode":
		call.Action = provider.ToolActionSwitchMode
		call.Output = boundedOutput(input.Plan)
		title = "Proposed plan"
	case "EnterPlanMode", "EnterWorktree", "ExitWorktree":
		call.Action = provider.ToolActionSwitchMode
	case "TodoWrite":
		state.itemKind = ""
	}
	state.call = call
	state.title = title
	return state
}

func splitMCPToolName(name string) (string, string, bool) {
	if !strings.HasPrefix(name, "mcp__") {
		return "", "", false
	}
	parts := strings.SplitN(strings.TrimPrefix(name, "mcp__"), "__", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", false
	}
	return parts[0], parts[1], true
}

func planEntriesFromInput(rawInput json.RawMessage) []provider.PlanEntry {
	var input struct {
		Todos []struct {
			Content string `json:"content"`
			Status  string `json:"status"`
		} `json:"todos"`
	}
	if len(rawInput) == 0 || json.Unmarshal(rawInput, &input) != nil || len(input.Todos) == 0 {
		return nil
	}
	entries := make([]provider.PlanEntry, 0, len(input.Todos))
	for _, todo := range input.Todos {
		if strings.TrimSpace(todo.Content) == "" {
			continue
		}
		status := provider.PlanEntryStatusPending
		switch todo.Status {
		case "in_progress":
			status = provider.PlanEntryStatusInProgress
		case "completed":
			status = provider.PlanEntryStatusCompleted
		}
		entries = append(entries, provider.PlanEntry{Content: todo.Content, Status: status})
	}
	if len(entries) == 0 {
		return nil
	}
	return entries
}

// toolResultContent flattens a tool_result content payload into display text
// plus any image attachments.
func toolResultContent(raw json.RawMessage) (string, []provider.Attachment) {
	if len(raw) == 0 {
		return "", nil
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return text, nil
	}
	var blocks []contentBlock
	if json.Unmarshal(raw, &blocks) != nil {
		return "", nil
	}
	var parts []string
	var attachments []provider.Attachment
	for _, block := range blocks {
		switch block.Type {
		case "text":
			if block.Text != "" {
				parts = append(parts, block.Text)
			}
		case "image":
			if block.Source != nil && block.Source.Data != "" {
				attachments = append(attachments, provider.Attachment{Kind: "image", MimeType: block.Source.MediaType, Data: block.Source.Data})
			}
		}
	}
	return strings.Join(parts, "\n"), attachments
}

func turnStateFromResult(result resultMessage) (provider.RuntimeTurnState, string, string) {
	stopReason := firstNonEmpty(result.TerminalReason, result.StopReason, result.Subtype)
	if strings.Contains(result.TerminalReason, "aborted") {
		return provider.RuntimeTurnInterrupted, stopReason, ""
	}
	message := resultErrorMessage(result)
	if result.Subtype == "success" && !result.IsError {
		return provider.RuntimeTurnCompleted, stopReason, ""
	}
	if message == "" && strings.HasPrefix(result.Subtype, "error_") {
		message = provider.HumanizeIdentifier(strings.TrimPrefix(result.Subtype, "error_"))
	}
	return provider.RuntimeTurnFailed, stopReason, message
}

// resultErrorMessage extracts a user-facing error, skipping the CLI's internal
// "[ede_diagnostic]" telemetry entries which must never become the banner.
func resultErrorMessage(result resultMessage) string {
	for _, entry := range result.Errors {
		entry = strings.TrimSpace(entry)
		if entry == "" || strings.HasPrefix(entry, "[ede_diagnostic]") {
			continue
		}
		return entry
	}
	if result.IsError {
		return strings.TrimSpace(result.Result)
	}
	return ""
}

func tokenUsageFromResult(result resultMessage) *provider.TokenUsage {
	var usage resultUsage
	if len(result.Usage) > 0 {
		_ = json.Unmarshal(result.Usage, &usage)
	}
	used := usage.InputTokens + usage.CacheCreationInputTokens + usage.CacheReadInputTokens + usage.OutputTokens
	if count := len(usage.Iterations); count > 0 {
		// The final iteration reflects the live context after the turn.
		last := usage.Iterations[count-1]
		used = last.InputTokens + last.CacheCreationInputTokens + last.CacheReadInputTokens + last.OutputTokens
	}
	window := 0
	for _, model := range result.ModelUsage {
		if model.ContextWindow > window {
			window = model.ContextWindow
		}
	}
	if used == 0 && window == 0 && result.TotalCostUSD == 0 {
		return nil
	}
	return &provider.TokenUsage{UsedTokens: used, MaxTokens: window, Cost: result.TotalCostUSD, Currency: costCurrency(result.TotalCostUSD)}
}

func costCurrency(cost float64) string {
	if cost > 0 {
		return "USD"
	}
	return ""
}

// userContentBlocks converts one SendTurn into API user message content.
func userContentBlocks(input provider.SendTurnInput) ([]map[string]any, error) {
	blocks := make([]map[string]any, 0, 1+len(input.Attachments))
	if strings.TrimSpace(input.Input) != "" {
		blocks = append(blocks, map[string]any{"type": "text", "text": input.Input})
	}
	for _, attachment := range input.Attachments {
		kind := strings.ToLower(strings.TrimSpace(attachment.Kind))
		switch kind {
		case "", "text":
			if attachment.Data != "" {
				blocks = append(blocks, map[string]any{"type": "text", "text": attachment.Data})
			}
		case "image":
			mediaType := trimmedOrDefault(attachment.MimeType, "image/png")
			data := strings.TrimSpace(attachment.Data)
			if cut := strings.Index(data, ";base64,"); strings.HasPrefix(strings.ToLower(data), "data:") && cut >= 0 {
				mediaType = data[len("data:"):cut]
				data = data[cut+len(";base64,"):]
			}
			if data == "" {
				return nil, fmt.Errorf("Claude Code image attachment requires inline base64 data")
			}
			blocks = append(blocks, map[string]any{"type": "image", "source": map[string]any{"type": "base64", "media_type": mediaType, "data": data}})
		default:
			return nil, fmt.Errorf("Claude Code does not accept attachment kind %q", attachment.Kind)
		}
	}
	if len(blocks) == 0 {
		return nil, fmt.Errorf("Claude Code turn requires text or attachments")
	}
	return blocks, nil
}

func slashCommandsFromSDK(commands []sdkCommand) []provider.SlashCommand {
	result := make([]provider.SlashCommand, 0, len(commands))
	for _, command := range commands {
		if strings.TrimSpace(command.Name) == "" {
			continue
		}
		result = append(result, provider.SlashCommand{
			Name:        command.Name,
			Description: command.Description,
			HasInput:    command.ArgumentHint != "",
			InputHint:   command.ArgumentHint,
		})
	}
	return result
}

func approvalRequestType(toolName string) provider.RuntimeRequestType {
	switch toolName {
	case "Bash", "BashOutput", "KillShell":
		return provider.RuntimeRequestCommandExecution
	case "Edit", "Write", "NotebookEdit":
		return provider.RuntimeRequestFileChange
	case "Read":
		return provider.RuntimeRequestFileRead
	default:
		return provider.RuntimeRequestDynamicToolCall
	}
}

func approvalDetail(request controlRequestBody) string {
	if reason := strings.TrimSpace(request.DecisionReason); reason != "" {
		return reason
	}
	var input toolInput
	if len(request.Input) > 0 {
		_ = json.Unmarshal(request.Input, &input)
	}
	for _, candidate := range []string{input.Command, input.FilePath, input.Plan, input.URL, request.Description, request.Title} {
		if strings.TrimSpace(candidate) != "" {
			return strings.TrimSpace(candidate)
		}
	}
	return request.ToolName
}

// permissionResponse builds the PermissionResult payload for a decision and
// reports the decision that should be echoed on request.resolved.
func permissionResponse(pending *pendingApproval, decision string) (map[string]any, provider.ApprovalDecision) {
	if pending.question != nil && strings.HasPrefix(decision, "answer:") {
		index := 0
		_, _ = fmt.Sscanf(decision, "answer:%d", &index)
		first := pending.question.Questions[0]
		if index >= 0 && index < len(first.Options) {
			var original map[string]any
			_ = json.Unmarshal(pending.input, &original)
			if original == nil {
				original = map[string]any{}
			}
			// Answers key by the full question text; the SDK looks answers up
			// by question text when folding them into the tool result.
			original["answers"] = map[string]string{first.Question: first.Options[index].Label}
			return map[string]any{"behavior": "allow", "updatedInput": original}, provider.ApprovalDecisionAccept
		}
	}
	switch decision {
	case "accept":
		return map[string]any{"behavior": "allow", "updatedInput": json.RawMessage(pending.input)}, provider.ApprovalDecisionAccept
	case "acceptForSession":
		return map[string]any{
			"behavior":           "allow",
			"updatedInput":       json.RawMessage(pending.input),
			"updatedPermissions": sessionScopedPermissions(pending),
		}, provider.ApprovalDecisionAcceptForSession
	case "decline":
		return map[string]any{"behavior": "deny", "message": "The user declined this action."}, provider.ApprovalDecisionDecline
	default:
		return map[string]any{"behavior": "deny", "message": "The user cancelled this request.", "interrupt": true}, provider.ApprovalDecisionCancel
	}
}

// sessionScopedPermissions rewrites the CLI's permission suggestions to the
// session destination so a session-only approval never persists to settings
// files, falling back to a whole-tool session allow rule.
func sessionScopedPermissions(pending *pendingApproval) []map[string]any {
	updates := make([]map[string]any, 0, len(pending.suggestions))
	for _, raw := range pending.suggestions {
		var suggestion map[string]any
		if json.Unmarshal(raw, &suggestion) != nil || suggestion == nil {
			continue
		}
		suggestion["destination"] = "session"
		updates = append(updates, suggestion)
	}
	if len(updates) == 0 && pending.toolName != "" {
		updates = append(updates, map[string]any{
			"type":        "addRules",
			"rules":       []map[string]any{{"toolName": pending.toolName}},
			"behavior":    "allow",
			"destination": "session",
		})
	}
	return updates
}

func boundedOutput(value string) string {
	if len(value) <= toolOutputLimit {
		return value
	}
	cut := toolOutputLimit
	for cut > 0 && !utf8.RuneStart(value[cut]) {
		cut--
	}
	return value[:cut]
}

func boundedRunes(value string, limit int) string {
	if limit <= 0 {
		return ""
	}
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit])
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
