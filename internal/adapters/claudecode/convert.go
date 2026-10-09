package claudecode

import (
	"encoding/json"
	"fmt"
	"html"
	"regexp"
	"slices"
	"strings"

	"github.com/Aqothy/maiD/internal/adapters/elicitation"
	"github.com/Aqothy/maiD/internal/adapters/unifieddiff"
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
	state := &toolState{itemKind: provider.ItemKindToolCall, input: rawInput}
	call := provider.ToolCall{Name: name, ProviderKind: name}
	title := name

	if server, tool, ok := splitMCPToolName(name); ok {
		call.Name = tool
		call.Namespace = server
		state.itemKind = provider.ItemKindMCPToolCall
		state.call = call
		state.title = strings.Trim(server+" · "+tool, " ·")
		return state
	}

	// Action is set only for built-ins whose own identity is a file read or
	// search (Claude Code's isSearchOrReadCommand for Read, Grep, and Glob).
	switch name {
	case "Bash":
		state.itemKind = provider.ItemKindCommandExecution
		call.Command = input.Command
		title = trimmedOrDefault(input.Description, "Ran command")
	case "Edit":
		state.itemKind = provider.ItemKindFileChange
		if input.FilePath != "" {
			call.Changes = []provider.FileChange{{Path: input.FilePath, Kind: provider.FileChangeUpdate, OldText: input.OldString, NewText: input.NewString}}
			call.Locations = []provider.ToolLocation{{Path: input.FilePath}}
		}
		title = "Edited file"
	case "Write":
		// Whether Write creates or replaces the file is known only from
		// its result (see applyResult).
		state.itemKind = provider.ItemKindFileChange
		if input.FilePath != "" {
			call.Changes = []provider.FileChange{{Path: input.FilePath, NewText: input.Content}}
			call.Locations = []provider.ToolLocation{{Path: input.FilePath}}
		}
		title = "Wrote file"
	case "NotebookEdit":
		state.itemKind = provider.ItemKindFileChange
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
		call.Query = input.Query
		title = trimmedOrDefault(input.Query, "Searched the web")
	case "WebFetch":
		call.Query = input.URL
		title = trimmedOrDefault(input.URL, "Fetched URL")
	case "Task", "Agent":
		call.Query = input.SubagentType
		title = trimmedOrDefault(input.Description, "Delegated to agent")
	case "Skill":
		call.Query = firstNonEmpty(input.Skill, input.Command)
		title = trimmedOrDefault("Skill "+call.Query, "Ran skill")
	case "ExitPlanMode":
		call.Output = boundedOutput(input.Plan)
		title = "Proposed plan"
	case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet":
		// The plan tools surface as the turn's plan, not as timeline items.
		state.itemKind = ""
	}
	state.call = call
	state.title = title
	return state
}

// applyResult records a tool's result on its snapshot and returns the item's
// final status. result is the tool's structured result, which for file edits
// carries the patch the CLI applied.
func (s *toolState) applyResult(block contentBlock, result json.RawMessage) provider.ItemStatus {
	output, attachments := toolResultContent(block.Content)
	status := provider.ItemStatusCompleted
	if block.IsError {
		status = provider.ItemStatusFailed
		s.call.Error = boundedOutput(output)
	} else {
		s.call.Output = boundedOutput(output)
	}
	s.call.Attachments = append(s.call.Attachments, attachments...)
	if !block.IsError && len(s.call.Changes) == 1 {
		applyFileResult(&s.call.Changes[0], result)
	}
	// A tool that started a background task (a Bash command run in the
	// background, an async agent) runs on until the task's notification.
	var launch struct {
		BackgroundTaskID string `json:"backgroundTaskId"`
		IsAsync          bool   `json:"isAsync"`
	}
	if !block.IsError && json.Unmarshal(result, &launch) == nil && (launch.BackgroundTaskID != "" || launch.IsAsync) {
		return provider.ItemStatusInProgress
	}
	return status
}

// taskNotification is the end of a background task, which the CLI reports
// live as system/task_notification and records in the transcript as a
// <task-notification> message.
type taskNotification struct {
	ToolUseID string `json:"tool_use_id"`
	Status    string `json:"status"`
	Summary   string `json:"summary"`
}

var taskNotificationPattern = regexp.MustCompile(`(?s)<tool-use-id>(.*?)</tool-use-id>.*?<status>(.*?)</status>(?:.*?<summary>(.*?)</summary>)?`)

// parseTaskNotification reads a <task-notification> message.
func parseTaskNotification(text string) (taskNotification, bool) {
	match := taskNotificationPattern.FindStringSubmatch(text)
	if match == nil {
		return taskNotification{}, false
	}
	return taskNotification{ToolUseID: match[1], Status: match[2], Summary: html.UnescapeString(match[3])}, true
}

// finish ends the background task of a tool: its summary becomes the output.
func (s *toolState) finish(notification taskNotification) provider.ItemStatus {
	if summary := strings.TrimSpace(notification.Summary); summary != "" {
		s.call.Output = boundedOutput(summary)
	}
	switch notification.Status {
	case "completed":
		return provider.ItemStatusCompleted
	case "failed":
		return provider.ItemStatusFailed
	default:
		return provider.ItemStatusInterrupted
	}
}

// fileEditResult is the structured result of Edit and Write.
type fileEditResult struct {
	// Type is "create" or "update" for Write.
	Type            string `json:"type"`
	Content         string `json:"content"`
	StructuredPatch []struct {
		OldStart int      `json:"oldStart"`
		OldLines int      `json:"oldLines"`
		NewStart int      `json:"newStart"`
		NewLines int      `json:"newLines"`
		Lines    []string `json:"lines"`
	} `json:"structuredPatch"`
}

// applyFileResult replaces a change's snippet with the patch the CLI applied,
// whose hunks have real line numbers.
func applyFileResult(change *provider.FileChange, raw json.RawMessage) {
	var result fileEditResult
	if len(raw) == 0 || json.Unmarshal(raw, &result) != nil {
		return
	}
	var diff strings.Builder
	switch {
	case result.Type == "create":
		change.Kind = provider.FileChangeAdd
		diff.WriteString(unifieddiff.WholeFile(result.Content, true))
	case len(result.StructuredPatch) > 0:
		change.Kind = provider.FileChangeUpdate
		for _, hunk := range result.StructuredPatch {
			diff.WriteString(unifieddiff.Hunk(hunk.OldStart, hunk.OldLines, hunk.NewStart, hunk.NewLines, hunk.Lines))
		}
	default:
		return
	}
	change.Diff = diff.String()
	change.OldText, change.NewText = "", ""
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
				attachments = append(attachments, provider.Attachment{Kind: provider.AttachmentImage, MimeType: block.Source.MediaType, Data: block.Source.Data})
			}
		}
	}
	return strings.Join(parts, "\n"), attachments
}

func turnStateFromResult(result resultMessage) (provider.RuntimeTurnState, provider.StopReason, string) {
	if strings.Contains(result.TerminalReason, "aborted") {
		return provider.RuntimeTurnInterrupted, "", ""
	}
	if result.Subtype == "error_max_turns" {
		// The agent ran out of turns: a completed turn that ended early.
		return provider.RuntimeTurnCompleted, provider.StopReasonMaxTurnRequests, ""
	}
	if result.Subtype == "success" && !result.IsError {
		switch result.StopReason {
		case "max_tokens":
			return provider.RuntimeTurnCompleted, provider.StopReasonMaxTokens, ""
		case "refusal":
			return provider.RuntimeTurnCompleted, provider.StopReasonRefusal, ""
		default:
			return provider.RuntimeTurnCompleted, "", ""
		}
	}
	message := resultErrorMessage(result)
	if message == "" && strings.HasPrefix(result.Subtype, "error_") {
		message = strings.TrimPrefix(result.Subtype, "error_")
	}
	return provider.RuntimeTurnFailed, "", message
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

// tokenUsageFromResult reads a result's usage. The context window is the
// session model's: subagents on other models report theirs too.
func tokenUsageFromResult(result resultMessage, model string) *provider.TokenUsage {
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
	window := result.ModelUsage[model].ContextWindow
	if window == 0 {
		for _, usage := range result.ModelUsage {
			window = max(window, usage.ContextWindow)
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
		switch attachment.Kind {
		case provider.AttachmentResourceLink:
			// Claude Code resolves files mentioned as `@path` in the prompt
			// text itself; the link carries nothing more.
		case provider.AttachmentImage:
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

// approvalRequestType is the permission a tool asks for; questions ask for
// none.
func approvalRequestType(toolName string) provider.RuntimeRequestType {
	switch toolName {
	case "AskUserQuestion":
		return ""
	case "Bash":
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

// approvalResponse builds the control response for a pending request: a
// permission decision, AskUserQuestion answers, or an MCP elicitation result.
func approvalResponse(pending *pendingApproval, input provider.RespondToRequestInput) (map[string]any, provider.ApprovalDecision, error) {
	switch {
	case pending.isElicitation:
		action := elicitation.ActionFor(input.Decision)
		response := map[string]any{"action": action}
		if action == elicitation.ActionAccept && pending.form != nil {
			content, err := pending.form.Content(input.Answers)
			if err != nil {
				return nil, "", err
			}
			response["content"] = content
		}
		return response, action.Decision(), nil
	case pending.question != nil:
		return questionResponse(pending, input)
	default:
		decision := string(input.Decision)
		if input.OptionID != "" {
			decision = input.OptionID
		}
		payload, resolved := permissionResponse(pending, decision)
		return payload, resolved, nil
	}
}

// questionResponse answers AskUserQuestion through updatedInput.answers, keyed
// by question text, with several selections joined by ", ". Declining or
// dismissing tells the model without interrupting the turn.
func questionResponse(pending *pendingApproval, input provider.RespondToRequestInput) (map[string]any, provider.ApprovalDecision, error) {
	switch input.Decision {
	case provider.ApprovalDecisionAccept:
	case provider.ApprovalDecisionDecline:
		return map[string]any{"behavior": "deny", "message": "The user declined to answer."}, provider.ApprovalDecisionDecline, nil
	default:
		return map[string]any{"behavior": "deny", "message": "The user dismissed the question without answering."}, provider.ApprovalDecisionCancel, nil
	}
	answers := make(map[string]string, len(pending.question.Questions))
	for _, question := range pending.question.Questions {
		values := slices.DeleteFunc(slices.Clone(input.Answers[question.Question]), func(value string) bool { return strings.TrimSpace(value) == "" })
		if len(values) == 0 {
			return nil, "", fmt.Errorf("%q needs an answer", question.Question)
		}
		if !question.MultiSelect && len(values) > 1 {
			return nil, "", fmt.Errorf("%q takes a single answer", question.Question)
		}
		answers[question.Question] = strings.Join(values, ", ")
	}
	var updated map[string]any
	_ = json.Unmarshal(pending.input, &updated)
	if updated == nil {
		updated = map[string]any{}
	}
	updated["answers"] = answers
	return map[string]any{"behavior": "allow", "updatedInput": updated}, provider.ApprovalDecisionAccept, nil
}

// permissionResponse builds the PermissionResult payload for a decision and
// reports the decision that should be echoed on request.resolved.
func permissionResponse(pending *pendingApproval, decision string) (map[string]any, provider.ApprovalDecision) {
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
// files.
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
	return updates
}

func boundedOutput(value string) string {
	return provider.TruncateUTF8(value, toolOutputLimit)
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
