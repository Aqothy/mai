package claudecode

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/Aqothy/maiD/internal/provider"
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
	// Error is set on an assistant message the API failed to produce, e.g.
	// "authentication_failed".
	Error string `json:"error,omitempty"`
	// NewConversationID is the session a conversation_reset (/clear)
	// continues in.
	NewConversationID string `json:"new_conversation_id,omitempty"`
	// IsReplay marks a user line that echoes a message the host wrote, sent
	// when the CLI takes it into a query (--replay-user-messages).
	IsReplay bool `json:"isReplay,omitempty"`
	// ToolUseResult is the structured result of the tool a user line's
	// tool_result answers.
	ToolUseResult json.RawMessage `json:"tool_use_result,omitempty"`
	Raw           json.RawMessage `json:"-"`
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
	// Model is the resolved model id, e.g. after /model.
	Model string `json:"model,omitempty"`
}

type systemStatus struct {
	PermissionMode string `json:"permissionMode,omitempty"`
	// Status is "compacting" while the CLI compacts, else null.
	Status        *string `json:"status"`
	CompactResult string  `json:"compact_result,omitempty"`
	CompactError  string  `json:"compact_error,omitempty"`
}

// systemInformational is a notice the CLI shows the user, such as a prompt a
// hook blocked (PreventContinuation).
type systemInformational struct {
	Content             string `json:"content"`
	Level               string `json:"level"`
	PreventContinuation bool   `json:"prevent_continuation,omitempty"`
}

// apiRetry is the system/api_retry message the CLI sends before retrying a
// failed API request.
type apiRetry struct {
	Attempt     int    `json:"attempt"`
	MaxRetries  int    `json:"max_retries"`
	ErrorStatus *int   `json:"error_status,omitempty"`
	Error       string `json:"error,omitempty"`
}

func (r apiRetry) message() string {
	cause := strings.ReplaceAll(trimmedOrDefault(r.Error, "unknown error"), "_", " ")
	if r.ErrorStatus != nil {
		cause = fmt.Sprintf("%s, HTTP %d", cause, *r.ErrorStatus)
	}
	return fmt.Sprintf("Claude API request failed (%s). Retrying, attempt %d of %d.", cause, r.Attempt, r.MaxRetries)
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
	// SuppressAlwaysAllowRule says the request must not offer a lasting
	// approval.
	SuppressAlwaysAllowRule bool   `json:"suppress_always_allow_rule,omitempty"`
	ToolUseID               string `json:"tool_use_id,omitempty"`
	Description             string `json:"description,omitempty"`
	Title                   string `json:"title,omitempty"`
	DecisionReason          string `json:"decision_reason,omitempty"`
	// MCP elicitation fields (subtype "elicitation").
	MCPServerName   string          `json:"mcp_server_name,omitempty"`
	Message         string          `json:"message,omitempty"`
	Mode            string          `json:"mode,omitempty"`
	URL             string          `json:"url,omitempty"`
	RequestedSchema json.RawMessage `json:"requested_schema,omitempty"`
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
	// CurrentPermissionMode is the mode the session starts in: the launch
	// flag, else the user's configured default.
	CurrentPermissionMode string `json:"current_permission_mode,omitempty"`
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
	Type       string `json:"type"`
	Subtype    string `json:"subtype,omitempty"`
	UUID       string `json:"uuid,omitempty"`
	ParentUUID string `json:"parentUuid,omitempty"`
	TeamName   string `json:"teamName,omitempty"`
	// IsAPIErrorMessage marks an assistant message the CLI wrote for a failed
	// API request; its text is the error.
	IsAPIErrorMessage bool            `json:"isApiErrorMessage,omitempty"`
	SessionID         string          `json:"sessionId,omitempty"`
	Timestamp         string          `json:"timestamp,omitempty"`
	IsSidechain       bool            `json:"isSidechain,omitempty"`
	IsMeta            bool            `json:"isMeta,omitempty"`
	Cwd               string          `json:"cwd,omitempty"`
	Message           json.RawMessage `json:"message,omitempty"`
	AITitle           string          `json:"aiTitle,omitempty"`
	CustomTitle       string          `json:"customTitle,omitempty"`
	// IsCompactSummary marks the summary the CLI writes as a user message
	// after compacting; the user never typed it.
	IsCompactSummary          bool `json:"isCompactSummary,omitempty"`
	IsVisibleInTranscriptOnly bool `json:"isVisibleInTranscriptOnly,omitempty"`
	// ToolUseResult is the structured result of the tool a tool_result
	// answers, as on a live user message.
	ToolUseResult json.RawMessage `json:"toolUseResult,omitempty"`
	// Origin says who sent a user message. It is absent on older lines and
	// for prompts typed by the user, whose kind is "human".
	Origin     *messageOrigin  `json:"origin,omitempty"`
	Attachment *transcriptItem `json:"attachment,omitempty"`
}

type messageOrigin struct {
	Kind string `json:"kind"`
}

// fromUser reports whether a message origin is the user.
func (o *messageOrigin) fromUser() bool {
	return o == nil || o.Kind == "" || o.Kind == "human"
}

// transcriptItem is an attachment line's payload. A prompt the CLI folded
// into a running query (a steer) is persisted only as a queued_command
// attachment, never as a user line.
type transcriptItem struct {
	Type        string          `json:"type"`
	CommandMode string          `json:"commandMode,omitempty"`
	Prompt      json.RawMessage `json:"prompt,omitempty"`
	Origin      *messageOrigin  `json:"origin,omitempty"`
}

// askUserQuestion mirrors the AskUserQuestionInput tool schema. Answers are
// returned via updatedInput as {questions, answers: {questionText: answer}},
// with several selections joined by ", ". The user may always type an answer
// of their own instead of choosing an option.
type askUserQuestion struct {
	Questions []struct {
		Question    string `json:"question"`
		MultiSelect bool   `json:"multiSelect,omitempty"`
		Options     []struct {
			Label       string `json:"label"`
			Description string `json:"description,omitempty"`
		} `json:"options,omitempty"`
	} `json:"questions"`
}

// userInput presents the questions as a provider-neutral request, keyed by
// question text as the answers are.
func (q askUserQuestion) request() provider.Request {
	request := provider.Request{Message: "Claude has a question.", Actions: []provider.RequestAction{
		{ID: "accept", Label: "Submit", Decision: provider.ApprovalDecisionAccept, Submit: true},
		{ID: "decline", Label: "Decline", Decision: provider.ApprovalDecisionDecline},
	}}
	if len(q.Questions) > 1 {
		request.Message = "Claude has questions."
	}
	for _, question := range q.Questions {
		converted := provider.Question{ID: question.Question, Kind: provider.QuestionKindChoice, Title: question.Question, Required: true, MultiSelect: question.MultiSelect, AllowsFreeText: true}
		for _, option := range question.Options {
			converted.Options = append(converted.Options, provider.QuestionOption{Value: option.Label, Label: option.Label, Description: option.Description})
		}
		request.Questions = append(request.Questions, converted)
	}
	return request
}

func trimmedOrDefault(value, fallback string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return fallback
	}
	return value
}
