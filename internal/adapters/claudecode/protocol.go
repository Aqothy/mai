package claudecode

import (
	"encoding/json"
	"strings"
)

// Wire DTOs for the Claude Code CLI stream-json protocol. The shapes mirror
// the official Agent SDK typings (@anthropic-ai/claude-agent-sdk) because the
// CLI speaks the same protocol to every SDK; maiD is simply another host.
// These types deliberately import nothing from the provider contract so the
// protocol layer stays extractable as a standalone client library.

// sdkMessage is the envelope for every stdout line. Only the discriminating
// fields are decoded eagerly; type-specific payloads keep their raw bytes so
// unknown message kinds pass through without loss.
type sdkMessage struct {
	Type            string          `json:"type"`
	Subtype         string          `json:"subtype,omitempty"`
	SessionID       string          `json:"session_id,omitempty"`
	UUID            string          `json:"uuid,omitempty"`
	ParentToolUseID *string         `json:"parent_tool_use_id,omitempty"`
	Message         json.RawMessage `json:"message,omitempty"`
	Event           json.RawMessage `json:"event,omitempty"`
	RequestID       string          `json:"request_id,omitempty"`
	Request         json.RawMessage `json:"request,omitempty"`
	Response        json.RawMessage `json:"response,omitempty"`
	Raw             json.RawMessage `json:"-"`
}

// apiMessage is the Anthropic API message carried by assistant/user lines.
type apiMessage struct {
	ID         string         `json:"id,omitempty"`
	Role       string         `json:"role,omitempty"`
	Model      string         `json:"model,omitempty"`
	Content    []contentBlock `json:"content,omitempty"`
	StopReason string         `json:"stop_reason,omitempty"`
	Usage      *apiUsage      `json:"usage,omitempty"`
}

// userAPIMessage tolerates the string-content form of user messages.
type userAPIMessage struct {
	Role    string          `json:"role,omitempty"`
	Content json.RawMessage `json:"content,omitempty"`
}

func (m userAPIMessage) blocks() ([]contentBlock, string) {
	if len(m.Content) == 0 {
		return nil, ""
	}
	var text string
	if json.Unmarshal(m.Content, &text) == nil {
		return nil, text
	}
	var blocks []contentBlock
	if json.Unmarshal(m.Content, &blocks) == nil {
		return blocks, ""
	}
	return nil, ""
}

// contentBlock is a union of every content block variant maiD consumes.
type contentBlock struct {
	Type      string          `json:"type"`
	Text      string          `json:"text,omitempty"`
	Thinking  string          `json:"thinking,omitempty"`
	ID        string          `json:"id,omitempty"`
	Name      string          `json:"name,omitempty"`
	Input     json.RawMessage `json:"input,omitempty"`
	ToolUseID string          `json:"tool_use_id,omitempty"`
	Content   json.RawMessage `json:"content,omitempty"`
	IsError   bool            `json:"is_error,omitempty"`
	Source    *imageSource    `json:"source,omitempty"`
}

type imageSource struct {
	Type      string `json:"type"`
	MediaType string `json:"media_type,omitempty"`
	Data      string `json:"data,omitempty"`
	URL       string `json:"url,omitempty"`
}

type apiUsage struct {
	InputTokens              int `json:"input_tokens"`
	OutputTokens             int `json:"output_tokens"`
	CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
	CacheReadInputTokens     int `json:"cache_read_input_tokens"`
}

func (u apiUsage) contextTokens() int {
	return u.InputTokens + u.CacheCreationInputTokens + u.CacheReadInputTokens + u.OutputTokens
}

// streamEvent is the payload of a stream_event line (raw API stream chunk).
type streamEvent struct {
	Type         string        `json:"type"`
	Index        int           `json:"index,omitempty"`
	ContentBlock *contentBlock `json:"content_block,omitempty"`
	Delta        *streamDelta  `json:"delta,omitempty"`
	Message      *apiMessage   `json:"message,omitempty"`
	Usage        *apiUsage     `json:"usage,omitempty"`
}

type streamDelta struct {
	Type        string `json:"type"`
	Text        string `json:"text,omitempty"`
	Thinking    string `json:"thinking,omitempty"`
	PartialJSON string `json:"partial_json,omitempty"`
	StopReason  string `json:"stop_reason,omitempty"`
}

// systemInit is the system/init message emitted once per process at the start
// of the first turn.
type systemInit struct {
	SessionID      string            `json:"session_id"`
	Cwd            string            `json:"cwd,omitempty"`
	Model          string            `json:"model,omitempty"`
	PermissionMode string            `json:"permissionMode,omitempty"`
	Tools          []string          `json:"tools,omitempty"`
	SlashCommands  []string          `json:"slash_commands,omitempty"`
	Skills         []string          `json:"skills,omitempty"`
	Agents         []string          `json:"agents,omitempty"`
	McpServers     []mcpServerStatus `json:"mcp_servers,omitempty"`
}

type mcpServerStatus struct {
	Name   string `json:"name"`
	Status string `json:"status,omitempty"`
}

type systemStatus struct {
	Status         string `json:"status,omitempty"`
	PermissionMode string `json:"permissionMode,omitempty"`
}

// resultMessage terminates each turn.
type resultMessage struct {
	Subtype           string                `json:"subtype"`
	IsError           bool                  `json:"is_error"`
	Result            string                `json:"result,omitempty"`
	SessionID         string                `json:"session_id,omitempty"`
	StopReason        string                `json:"stop_reason,omitempty"`
	TerminalReason    string                `json:"terminal_reason,omitempty"`
	NumTurns          int                   `json:"num_turns,omitempty"`
	TotalCostUSD      float64               `json:"total_cost_usd,omitempty"`
	Usage             json.RawMessage       `json:"usage,omitempty"`
	ModelUsage        map[string]modelUsage `json:"modelUsage,omitempty"`
	PermissionDenials json.RawMessage       `json:"permission_denials,omitempty"`
	Errors            []string              `json:"errors,omitempty"`
}

type resultUsage struct {
	InputTokens              int `json:"input_tokens"`
	OutputTokens             int `json:"output_tokens"`
	CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
	CacheReadInputTokens     int `json:"cache_read_input_tokens"`
	Iterations               []struct {
		InputTokens              int `json:"input_tokens"`
		OutputTokens             int `json:"output_tokens"`
		CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
		CacheReadInputTokens     int `json:"cache_read_input_tokens"`
	} `json:"iterations,omitempty"`
}

type modelUsage struct {
	InputTokens   int     `json:"inputTokens"`
	OutputTokens  int     `json:"outputTokens"`
	CostUSD       float64 `json:"costUSD"`
	ContextWindow int     `json:"contextWindow"`
}

// controlRequestBody is the CLI→host control request payload. can_use_tool is
// the load-bearing subtype; the rest of the fields ride along for display.
type controlRequestBody struct {
	Subtype               string            `json:"subtype"`
	ToolName              string            `json:"tool_name,omitempty"`
	Input                 json.RawMessage   `json:"input,omitempty"`
	PermissionSuggestions []json.RawMessage `json:"permission_suggestions,omitempty"`
	ToolUseID             string            `json:"tool_use_id,omitempty"`
	AgentID               string            `json:"agent_id,omitempty"`
	DisplayName           string            `json:"display_name,omitempty"`
	Description           string            `json:"description,omitempty"`
	Title                 string            `json:"title,omitempty"`
	DecisionReason        string            `json:"decision_reason,omitempty"`
	BlockedPath           string            `json:"blocked_path,omitempty"`
}

// controlResponse correlates a control_response line to a pending request.
type controlResponse struct {
	Subtype   string          `json:"subtype"`
	RequestID string          `json:"request_id"`
	Response  json.RawMessage `json:"response,omitempty"`
	Error     string          `json:"error,omitempty"`
}

// initializeResponse is the success payload of the initialize control request.
type initializeResponse struct {
	Commands              []sdkCommand `json:"commands,omitempty"`
	Models                []sdkModel   `json:"models,omitempty"`
	Account               *sdkAccount  `json:"account,omitempty"`
	OutputStyle           string       `json:"output_style,omitempty"`
	CurrentPermissionMode string       `json:"current_permission_mode,omitempty"`
}

type sdkCommand struct {
	Name         string `json:"name"`
	Description  string `json:"description,omitempty"`
	ArgumentHint string `json:"argumentHint,omitempty"`
}

type sdkModel struct {
	Value                 string   `json:"value"`
	ResolvedModel         string   `json:"resolvedModel,omitempty"`
	DisplayName           string   `json:"displayName,omitempty"`
	Description           string   `json:"description,omitempty"`
	SupportsEffort        bool     `json:"supportsEffort,omitempty"`
	SupportedEffortLevels []string `json:"supportedEffortLevels,omitempty"`
}

type sdkAccount struct {
	Email            string `json:"email,omitempty"`
	Organization     string `json:"organization,omitempty"`
	SubscriptionType string `json:"subscriptionType,omitempty"`
	APIProvider      string `json:"apiProvider,omitempty"`
}

// transcriptLine is one persisted line of a session transcript under
// <configDir>/projects/<munged-cwd>/<session-id>.jsonl.
type transcriptLine struct {
	Type          string          `json:"type"`
	Subtype       string          `json:"subtype,omitempty"`
	UUID          string          `json:"uuid,omitempty"`
	ParentUUID    *string         `json:"parentUuid,omitempty"`
	SessionID     string          `json:"sessionId,omitempty"`
	Timestamp     string          `json:"timestamp,omitempty"`
	IsSidechain   bool            `json:"isSidechain,omitempty"`
	IsMeta        bool            `json:"isMeta,omitempty"`
	UserType      string          `json:"userType,omitempty"`
	Cwd           string          `json:"cwd,omitempty"`
	Message       json.RawMessage `json:"message,omitempty"`
	ToolUseResult json.RawMessage `json:"toolUseResult,omitempty"`
	AITitle       string          `json:"aiTitle,omitempty"`
	LastPrompt    string          `json:"lastPrompt,omitempty"`
}

// askUserQuestion mirrors the AskUserQuestionInput tool schema. Answers are
// returned via updatedInput as {questions, answers: {questionText: label}}.
type askUserQuestion struct {
	Questions []struct {
		Question    string `json:"question"`
		Header      string `json:"header,omitempty"`
		MultiSelect bool   `json:"multiSelect,omitempty"`
		Options     []struct {
			Label       string `json:"label"`
			Description string `json:"description,omitempty"`
		} `json:"options,omitempty"`
	} `json:"questions"`
}

func trimmedOrDefault(value, fallback string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return fallback
	}
	return value
}
