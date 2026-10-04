package claudecode

import (
	"encoding/json"
	"strings"
)

// Wire DTOs for the Claude Code CLI stream-json protocol, following the
// official Agent SDK typings (@anthropic-ai/claude-agent-sdk) because the CLI
// speaks the same protocol to every SDK; maiD is simply another host. Only the
// fields maiD consumes are modeled; unknown fields are ignored.
// These types deliberately import nothing from the provider contract so the
// protocol layer stays extractable as a standalone client library.

// sdkMessage is the envelope for every stdout line. Only the discriminating
// fields are decoded eagerly; type-specific payloads keep their raw bytes so
// unknown message kinds pass through without loss.
type sdkMessage struct {
	Type            string          `json:"type"`
	Subtype         string          `json:"subtype,omitempty"`
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
	ID      string         `json:"id,omitempty"`
	Content []contentBlock `json:"content,omitempty"`
}

// userAPIMessage tolerates the string-content form of user messages.
type userAPIMessage struct {
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
	MediaType string `json:"media_type,omitempty"`
	Data      string `json:"data,omitempty"`
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
	Usage        *apiUsage     `json:"usage,omitempty"`
}

type streamDelta struct {
	Type        string `json:"type"`
	Text        string `json:"text,omitempty"`
	Thinking    string `json:"thinking,omitempty"`
	PartialJSON string `json:"partial_json,omitempty"`
}

// systemInit is the system/init message emitted once per process at the start
// of the first turn.
type systemInit struct {
	SessionID      string `json:"session_id"`
	PermissionMode string `json:"permissionMode,omitempty"`
}

type systemStatus struct {
	PermissionMode string `json:"permissionMode,omitempty"`
}

// resultMessage terminates each turn.
type resultMessage struct {
	Subtype        string                `json:"subtype"`
	IsError        bool                  `json:"is_error"`
	Result         string                `json:"result,omitempty"`
	StopReason     string                `json:"stop_reason,omitempty"`
	TerminalReason string                `json:"terminal_reason,omitempty"`
	TotalCostUSD   float64               `json:"total_cost_usd,omitempty"`
	Usage          json.RawMessage       `json:"usage,omitempty"`
	ModelUsage     map[string]modelUsage `json:"modelUsage,omitempty"`
	Errors         []string              `json:"errors,omitempty"`
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
	ContextWindow int `json:"contextWindow"`
}

// controlRequestBody is the CLI→host control request payload. can_use_tool is
// the load-bearing subtype; the rest of the fields ride along for display.
type controlRequestBody struct {
	Subtype               string            `json:"subtype"`
	ToolName              string            `json:"tool_name,omitempty"`
	Input                 json.RawMessage   `json:"input,omitempty"`
	PermissionSuggestions []json.RawMessage `json:"permission_suggestions,omitempty"`
	ToolUseID             string            `json:"tool_use_id,omitempty"`
	Description           string            `json:"description,omitempty"`
	Title                 string            `json:"title,omitempty"`
	DecisionReason        string            `json:"decision_reason,omitempty"`
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
	Commands []sdkCommand `json:"commands,omitempty"`
	Models   []sdkModel   `json:"models,omitempty"`
	Account  *sdkAccount  `json:"account,omitempty"`
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
	SupportedEffortLevels []string `json:"supportedEffortLevels,omitempty"`
}

type sdkAccount struct {
	Email            string `json:"email,omitempty"`
	SubscriptionType string `json:"subscriptionType,omitempty"`
}

// transcriptLine is one persisted line of a session transcript under
// <configDir>/projects/<munged-cwd>/<session-id>.jsonl.
type transcriptLine struct {
	Type        string          `json:"type"`
	UUID        string          `json:"uuid,omitempty"`
	SessionID   string          `json:"sessionId,omitempty"`
	Timestamp   string          `json:"timestamp,omitempty"`
	IsSidechain bool            `json:"isSidechain,omitempty"`
	IsMeta      bool            `json:"isMeta,omitempty"`
	Cwd         string          `json:"cwd,omitempty"`
	Message     json.RawMessage `json:"message,omitempty"`
	AITitle     string          `json:"aiTitle,omitempty"`
}

// askUserQuestion mirrors the AskUserQuestionInput tool schema. Answers are
// returned via updatedInput as {questions, answers: {questionText: label}}.
type askUserQuestion struct {
	Questions []struct {
		Question string `json:"question"`
		Options  []struct {
			Label string `json:"label"`
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
