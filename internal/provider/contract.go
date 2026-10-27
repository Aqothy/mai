// Package provider defines the provider-neutral contract between the daemon
// and its adapters.
//
// Adapters speak native sessions: they translate a provider's protocol into
// sessions named by native keys, turns and entries named by deterministic
// native refs, and typed events. They never see maiD's own threads,
// participants or deliveries; native SDK DTOs stay inside adapter packages.
package provider

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"
)

type InstanceID string

type DriverKind string

// InstanceSpec describes a configured provider instance to materialize. Config
// is an opaque, driver-owned JSON envelope: providerservice routes and stores it
// without knowing whether the adapter runs a process, an SDK, or an in-process
// agent. Runtime event wiring is passed separately to the adapter factory.
type InstanceSpec struct {
	InstanceID InstanceID      `json:"instanceId,omitempty"`
	Name       string          `json:"name,omitempty"`
	Driver     DriverKind      `json:"driver,omitempty"`
	Config     json.RawMessage `json:"config,omitempty"`
}

// RequestError carries structured request errors returned by a provider through
// the daemon without depending on a specific provider SDK.
type RequestError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

func (e *RequestError) Error() string {
	if e == nil {
		return "<nil>"
	}
	if len(e.Data) > 0 {
		return fmt.Sprintf("%s: %s", e.Message, e.Data)
	}
	return e.Message
}

type InstanceStatus string

const (
	InstanceStatusConfigured  InstanceStatus = "configured"
	InstanceStatusInitialized InstanceStatus = "initialized"
	InstanceStatusExited      InstanceStatus = "exited"
)

// PromptContentCapabilities reports which non-text content blocks a provider
// accepts in a turn prompt.
type PromptContentCapabilities struct {
	Image           bool `json:"image,omitempty"`
	Audio           bool `json:"audio,omitempty"`
	EmbeddedContext bool `json:"embeddedContext,omitempty"`
}

// MCPCapabilities reports which MCP transports a provider can be given
// servers over (OpenInput.MCP).
type MCPCapabilities struct {
	HTTP  bool `json:"http,omitempty"`
	Stdio bool `json:"stdio,omitempty"`
}

// HistoryQuality is how well a provider rebuilds a session's conversation
// from its own record.
type HistoryQuality string

const (
	// HistoryNone: the provider can't replay sessions.
	HistoryNone HistoryQuality = "none"
	// HistoryLossy: replay leaves things out or shows them differently from
	// how they streamed.
	HistoryLossy HistoryQuality = "lossy"
	// HistoryExact: replay gives the entries the session streamed, ref for
	// ref; replay fixtures prove it.
	HistoryExact HistoryQuality = "exact"
)

// Capabilities says what an instance offers. Every Instance method exists on
// every instance; one its capabilities don't offer returns ErrUnsupported.
// Features read capabilities, never driver names, and clients read the same
// struct.
type Capabilities struct {
	// History is how a session the provider ran outside maiD rebuilds.
	// Sessions maiD ran always rebuild exactly: adapters keep what the
	// provider can't replay in the host's Mirror.
	History HistoryQuality `json:"history"`
	// HistoryVersion changes whenever the adapter maps native history to
	// entries differently, so entries cached by another version are rebuilt.
	HistoryVersion int `json:"historyVersion"`
	// Resume reopens a session with the agent's memory of it.
	Resume bool `json:"resume,omitempty"`
	// Fork forks a session natively through one of its turns.
	Fork bool `json:"fork,omitempty"`
	// Steer adds a message to a running turn.
	Steer bool `json:"steer,omitempty"`
	// Subagents emits SubagentSeen for the provider's own subagents.
	Subagents bool `json:"subagents,omitempty"`
	// Instructions puts OpenInput.Instructions in a system or developer
	// prompt; without it the daemon sends them with the first turn.
	Instructions bool `json:"instructions,omitempty"`
	// MessageIDs keeps SendInput.Delivery in the session, so Delivered is
	// exact rather than a match on the text sent.
	MessageIDs            bool                      `json:"messageIds,omitempty"`
	MCP                   MCPCapabilities           `json:"mcp,omitzero"`
	PromptContent         PromptContentCapabilities `json:"promptContent,omitzero"`
	AdditionalDirectories bool                      `json:"additionalDirectories,omitempty"`
	Sessions              bool                      `json:"sessions,omitempty"`
	Delete                bool                      `json:"delete,omitempty"`
	Rename                bool                      `json:"rename,omitempty"`
	Auth                  bool                      `json:"auth,omitempty"`
	Logout                bool                      `json:"logout,omitempty"`
	CommandCompletion     bool                      `json:"commandCompletion,omitempty"`
}

type AuthStatus string

const (
	AuthStatusUnknown         AuthStatus = "unknown"
	AuthStatusAuthenticated   AuthStatus = "authenticated"
	AuthStatusUnauthenticated AuthStatus = "unauthenticated"
)

// AuthKind is how a sign-in method or challenge proceeds.
type AuthKind string

const (
	AuthKindBrowser    AuthKind = "browser"
	AuthKindDeviceCode AuthKind = "device-code"
	AuthKindSecret     AuthKind = "secret"
	// AuthKindTerminal runs the agent's own login program in an interactive
	// terminal instead of an authenticate call.
	AuthKindTerminal AuthKind = "terminal"
)

type AuthMethod struct {
	ID             string   `json:"id"`
	Name           string   `json:"name,omitempty"`
	Description    string   `json:"description,omitempty"`
	Kind           AuthKind `json:"kind,omitempty"`
	RequiresSecret bool     `json:"requiresSecret,omitempty"`
}

type AuthenticateInput struct {
	MethodID string `json:"methodId"`
	Secret   string `json:"secret,omitempty"`
	// Ask shows the user a question the agent asks while signing in, outside
	// any thread, and waits for the answer. Nil when nobody can answer.
	Ask func(context.Context, Request) (RequestAnswer, error) `json:"-"`
}

// RequestAnswer is the action the user chose on a Request and, for an
// action that submits, the answers to its questions.
type RequestAnswer struct {
	Action  RequestAction
	Answers map[string][]string
}

// AuthChallenge describes a browser or device-code login that continues after
// provider.authenticate returns. Credentials are accepted in requests but are
// never echoed through this value or persisted by the daemon.
type AuthChallenge struct {
	Kind            AuthKind `json:"kind,omitempty"`
	LoginID         string   `json:"loginId,omitempty"`
	URL             string   `json:"url,omitempty"`
	UserCode        string   `json:"userCode,omitempty"`
	VerificationURL string   `json:"verificationUrl,omitempty"`
	// TerminalID names the maiD terminal running a terminal sign-in (Kind
	// "terminal"). The provider restarts once that program exits successfully.
	TerminalID string `json:"terminalId,omitempty"`
}

// TerminalCommand is a program to run in an interactive terminal: Argv, with
// Env (KEY=VALUE) overriding the inherited environment.
type TerminalCommand struct {
	Argv []string
	Env  []string
}

type AuthenticationResult struct {
	Instance  InstanceInfo   `json:"instance"`
	Challenge *AuthChallenge `json:"challenge,omitempty"`
	// Terminal asks the host to run this sign-in program in an interactive
	// terminal. The host reports it to clients as a terminal challenge and
	// restarts the provider once the program exits successfully.
	Terminal *TerminalCommand `json:"-"`
}

// Auth is the provider-neutral auth state surfaced to clients (for a provider
// picker / auth UI).
type Auth struct {
	Status  AuthStatus   `json:"status,omitempty"`
	Methods []AuthMethod `json:"methods,omitempty"`
}

// InstanceInfo describes a materialized provider instance owned by the server. It
// is what a provider-list/picker RPC returns, so it carries enough for the
// client to display and authenticate the provider. InstanceID is the
// client-chosen routing key used by every instance-scoped RPC.
type InstanceInfo struct {
	InstanceID    InstanceID     `json:"instanceId"`
	Name          string         `json:"name"`
	Driver        DriverKind     `json:"driver"`
	PID           int            `json:"pid,omitempty"`
	Status        InstanceStatus `json:"status"`
	StartedAt     time.Time      `json:"startedAt"`
	InitializedAt time.Time      `json:"initializedAt"`
	Capabilities  Capabilities   `json:"capabilities"`
	Auth          Auth           `json:"auth"`
	// Access says which config option sets a session's access and how much
	// each of its values allows; nil when the provider has no such option.
	Access *AccessModes `json:"access,omitempty"`
}

// SlashCommand is an agent-advertised command the client can offer (ACP
// available_commands_update).
type SlashCommand struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	HasInput    bool   `json:"hasInput,omitempty"`
	InputHint   string `json:"inputHint,omitempty"`
	// Completes says the provider suggests the command's input as it is
	// typed (provider.completeCommand), such as what a review should cover.
	Completes bool `json:"completes,omitempty"`
}

// CompleteCommandInput asks for suggestions for what follows a slash
// command, given what has been typed after its name.
type CompleteCommandInput struct {
	// Session is the live session the command runs in, if any.
	Session string
	Cwd     string
	Command string
	Input   string
}

// CommandCompletion is one suggestion for a slash command's input.
type CommandCompletion struct {
	// Input replaces everything typed after the command's name.
	Input       string `json:"input"`
	Label       string `json:"label"`
	Description string `json:"description,omitempty"`
}

// Skill is a provider-advertised, cwd-scoped prompt capability. A selected
// skill is sent as structured input by adapters that support it.
type Skill struct {
	Name             string `json:"name"`
	Description      string `json:"description,omitempty"`
	ShortDescription string `json:"shortDescription,omitempty"`
	Path             string `json:"path,omitempty"`
	Scope            string `json:"scope,omitempty"`
	Enabled          bool   `json:"enabled"`
}

type TokenUsage struct {
	UsedTokens int     `json:"usedTokens"`
	MaxTokens  int     `json:"maxTokens,omitempty"`
	Cost       float64 `json:"cost,omitempty"`
	Currency   string  `json:"currency,omitempty"`
}

// Goal is an objective the provider keeps working toward over turns of its
// own until it is met, such as one set with a /goal command.
type Goal struct {
	Objective   string     `json:"objective"`
	Status      GoalStatus `json:"status"`
	TokensUsed  int64      `json:"tokensUsed"`
	TokenBudget *int64     `json:"tokenBudget,omitempty"`
	// TimeUsedSeconds is the time spent on the goal when it was reported.
	TimeUsedSeconds int64 `json:"timeUsedSeconds"`
}

type GoalStatus string

const (
	GoalActive GoalStatus = "active"
	GoalPaused GoalStatus = "paused"
	// GoalBlocked: the provider stopped because it can't make progress.
	GoalBlocked GoalStatus = "blocked"
	// GoalUsageLimited: the account's usage limit stopped the goal.
	GoalUsageLimited GoalStatus = "usage_limited"
	// GoalBudgetLimited: the goal spent its token budget unmet.
	GoalBudgetLimited GoalStatus = "budget_limited"
	GoalComplete      GoalStatus = "complete"
)

type SessionSummary struct {
	SessionID             string   `json:"sessionId"`
	Title                 string   `json:"title,omitempty"`
	Cwd                   string   `json:"cwd,omitempty"`
	AdditionalDirectories []string `json:"additionalDirectories,omitempty"`
	UpdatedAt             string   `json:"updatedAt,omitempty"`
}

// PromptPreviewTitle is the session-list title derived from a session's first
// prompt when the provider has none: whitespace collapsed, at most 120 runes.
func PromptPreviewTitle(prompt string) string {
	title := strings.Join(strings.Fields(prompt), " ")
	if runes := []rune(title); len(runes) > 120 {
		return string(runes[:120])
	}
	return title
}

// TruncateUTF8 cuts text to at most limit bytes without splitting a rune.
// Adapters use it to bound tool output, since every update re-emits a tool's
// whole snapshot.
func TruncateUTF8(text string, limit int) string {
	if len(text) <= limit {
		return text
	}
	cut := max(limit, 0)
	for cut > 0 && !utf8.RuneStart(text[cut]) {
		cut--
	}
	return text[:cut]
}

// ConfigOptionCategory is a UX hint distinguishing kinds of settable session
// configuration options. It must be treated as advisory; unknown values are
// allowed and handled gracefully.
type ConfigOptionCategory string

const (
	ConfigOptionCategoryModel        ConfigOptionCategory = "model"
	ConfigOptionCategoryMode         ConfigOptionCategory = "mode"
	ConfigOptionCategoryModelConfig  ConfigOptionCategory = "model_config"
	ConfigOptionCategoryThoughtLevel ConfigOptionCategory = "thought_level"
	ConfigOptionCategoryOther        ConfigOptionCategory = "other"
)

type ConfigChoice struct {
	Value       string `json:"value"`
	Label       string `json:"label,omitempty"`
	Description string `json:"description,omitempty"`
	Group       string `json:"group,omitempty"`
	GroupLabel  string `json:"groupLabel,omitempty"`
}

type ConfigOptionType string

const (
	ConfigOptionTypeSelect  ConfigOptionType = "select"
	ConfigOptionTypeBoolean ConfigOptionType = "boolean"
)

// ConfigOption is a provider-neutral, settable session configuration option.
// CurrentValue is a string for select options and a bool for boolean options.
// Category is only a UX hint.
type ConfigOption struct {
	ID           string               `json:"id"`
	Type         ConfigOptionType     `json:"type"`
	Category     ConfigOptionCategory `json:"category,omitempty"`
	Label        string               `json:"label,omitempty"`
	Description  string               `json:"description,omitempty"`
	Choices      []ConfigChoice       `json:"choices,omitempty"`
	CurrentValue any                  `json:"currentValue,omitempty"`
}

// CurrentConfigString returns the current value of the select option optionID.
func CurrentConfigString(options []ConfigOption, optionID string) (string, bool) {
	for _, option := range options {
		if option.ID == optionID {
			value, ok := option.CurrentValue.(string)
			return value, ok
		}
	}
	return "", false
}

type ConfigOptionSelection struct {
	OptionID string               `json:"optionId"`
	Value    any                  `json:"value"`
	Category ConfigOptionCategory `json:"category,omitempty"`
}

// OptionsSession is a disposable provider-side helper used only to populate a
// draft's configuration controls. Handle is opaque outside the adapter.
type OptionsSession struct {
	Handle        string
	ConfigOptions []ConfigOption
	Skills        []Skill
}

// OptionsSessionCallbacks report changes of an OptionsSession made on the
// provider's side: new options, or the session ending.
type OptionsSessionCallbacks struct {
	Updated     func([]ConfigOption)
	Invalidated func()
}

// AttachmentKind is what an attachment carries.
type AttachmentKind string

const (
	AttachmentImage AttachmentKind = "image"
	AttachmentAudio AttachmentKind = "audio"
	// AttachmentResource embeds a file's contents (Data, named by URI).
	AttachmentResource AttachmentKind = "resource"
	// AttachmentResourceLink refers to a file or URI by URI, without its
	// contents, e.g. a file the prompt mentions.
	AttachmentResourceLink AttachmentKind = "resource_link"
)

type Attachment struct {
	// ID names a message attachment the daemon holds, so clients can fetch
	// its Data separately from thread snapshots. Orchestration assigns it (or
	// keeps the one a client uploaded the data under); adapters ignore it.
	ID               string              `json:"id,omitempty"`
	Kind             AttachmentKind      `json:"kind"`
	Name             string              `json:"name,omitempty"`
	Title            string              `json:"title,omitempty"`
	Description      string              `json:"description,omitempty"`
	MimeType         string              `json:"mimeType,omitempty"`
	Data             string              `json:"data,omitempty"`
	URI              string              `json:"uri,omitempty"`
	Size             int64               `json:"size,omitempty"`
	Annotations      *ContentAnnotations `json:"annotations,omitempty"`
	Metadata         map[string]any      `json:"_meta,omitempty"`
	ResourceMetadata map[string]any      `json:"resourceMeta,omitempty"`
}

// ContentAnnotations are ACP/MCP display hints attached to provider content.
// They are deliberately distinct from PromptAnnotation, which is authored by
// a user to quote and comment on transcript text.
type ContentAnnotations struct {
	Audience     []string       `json:"audience,omitempty"`
	Priority     *float64       `json:"priority,omitempty"`
	LastModified string         `json:"lastModified,omitempty"`
	Metadata     map[string]any `json:"_meta,omitempty"`
}

// PromptAnnotation is quoted conversation context selected by the user. It is
// kept separate from the visible draft so clients can render and persist
// annotation cards without injecting hidden markup.
type PromptAnnotation struct {
	ID        string `json:"id"`
	MessageID string `json:"messageId,omitempty"`
	Role      string `json:"role,omitempty"`
	Quote     string `json:"quote"`
	Note      string `json:"note,omitempty"`
}

type ApprovalDecision string

const (
	ApprovalDecisionAccept           ApprovalDecision = "accept"
	ApprovalDecisionAcceptForSession ApprovalDecision = "acceptForSession"
	ApprovalDecisionDecline          ApprovalDecision = "decline"
	ApprovalDecisionCancel           ApprovalDecision = "cancel"
)

// Request is what an agent asks the user, in one shape for every kind: a
// permission, a question or form, a yes or no, a link to open, a plan to
// review, a sign-in step. The actions are the only ways to answer it; an
// action that submits sends the answers to its questions, which are checked
// only then. A URL request asks for consent to open URL in the browser (for
// out-of-band flows such as OAuth); accepting it only means the user agreed
// to open it.
type Request struct {
	Message   string          `json:"message,omitempty"`
	URL       string          `json:"url,omitempty"`
	Questions []Question      `json:"questions,omitempty"`
	Actions   []RequestAction `json:"actions"`
	// Details is the provider's own description of what it asks (a tool's
	// input), shown on request as is.
	Details json.RawMessage `json:"details,omitempty"`
}

// RequestAction is one way to answer a Request. Decision is what choosing it
// means for the request's lifecycle and history; the adapter answers its
// provider by ID.
type RequestAction struct {
	ID       string           `json:"id"`
	Label    string           `json:"label"`
	Decision ApprovalDecision `json:"decision"`
	Submit   bool             `json:"submit,omitempty"`
}

// Action returns the request's action with the given ID.
func (r Request) Action(id string) (RequestAction, bool) {
	for _, action := range r.Actions {
		if action.ID == id {
			return action, true
		}
	}
	return RequestAction{}, false
}

type QuestionKind string

const (
	QuestionKindText    QuestionKind = "text"
	QuestionKindNumber  QuestionKind = "number"
	QuestionKindInteger QuestionKind = "integer"
	QuestionKindChoice  QuestionKind = "choice"
)

// Question is one field of a user-input request. Choice questions offer
// Options (one, or several when MultiSelect), and AllowsFreeText also takes a
// typed answer instead of an option. The other kinds take one typed value.
// Default holds the pre-filled answer, in the same form as an answer.
type Question struct {
	ID             string           `json:"id"`
	Kind           QuestionKind     `json:"kind"`
	Title          string           `json:"title,omitempty"`
	Description    string           `json:"description,omitempty"`
	Required       bool             `json:"required,omitempty"`
	MultiSelect    bool             `json:"multiSelect,omitempty"`
	AllowsFreeText bool             `json:"allowsFreeText,omitempty"`
	Options        []QuestionOption `json:"options,omitempty"`
	Default        []string         `json:"default,omitempty"`
}

type QuestionOption struct {
	Value       string `json:"value"`
	Label       string `json:"label"`
	Description string `json:"description,omitempty"`
}

// StopReason says why a completed turn ended early. It is empty when the turn
// finished normally; failures and cancellation are turn states instead.
type StopReason string

const (
	StopReasonMaxTokens       StopReason = "max_tokens"
	StopReasonMaxTurnRequests StopReason = "max_turn_requests"
	StopReasonRefusal         StopReason = "refusal"
)

// TurnState is a turn's lifecycle state.
type TurnState string

const (
	TurnRunning     TurnState = "running"
	TurnCompleted   TurnState = "completed"
	TurnFailed      TurnState = "failed"
	TurnInterrupted TurnState = "interrupted"
)

// Settled reports whether the turn ended.
func (s TurnState) Settled() bool { return s != TurnRunning }

// ItemKind is the kind of one entry of a session's conversation (Entry).
type ItemKind string

const (
	ItemKindUserMessage       ItemKind = "user_message"
	ItemKindAssistantMessage  ItemKind = "assistant_message"
	ItemKindReasoning         ItemKind = "reasoning"
	ItemKindCommandExecution  ItemKind = "command_execution"
	ItemKindFileChange        ItemKind = "file_change"
	ItemKindMCPToolCall       ItemKind = "mcp_tool_call"
	ItemKindToolCall          ItemKind = "tool_call"
	ItemKindWarning           ItemKind = "warning"
	ItemKindError             ItemKind = "error"
	ItemKindWebSearch         ItemKind = "web_search"
	ItemKindImageView         ItemKind = "image_view"
	ItemKindImageGeneration   ItemKind = "image_generation"
	ItemKindContextCompaction ItemKind = "context_compaction"
	// ItemKindEnvelope is a block maiD wrapped around text it sent the
	// session: a handoff, an agent's message, a reply, a notice (Envelope).
	ItemKindEnvelope ItemKind = "envelope"
	// ItemKindRequest records what was asked of the user and how it was
	// answered (RequestRecord). The daemon writes it; providers don't keep it.
	ItemKindRequest ItemKind = "request"
)

// IsTool reports whether entries of the kind carry a ToolCall.
func (k ItemKind) IsTool() bool {
	switch k {
	case ItemKindCommandExecution, ItemKindFileChange, ItemKindMCPToolCall, ItemKindToolCall:
		return true
	}
	return false
}

// ToolAction is a semantic action a provider explicitly states for a tool
// call. The empty value means the provider stated none, which is the normal
// case: clients then identify the call by its raw Name.
//
// Adapters set it ONLY from what the provider itself states: its protocol's
// tool kind (ACP "read"/"search"), its own parsed command actions (Codex
// commandActions), or the identity of one of its own built-in tools (Claude
// Code's Read, Grep, Glob). Never infer it from a tool or command name, and
// leave it empty for MCP, dynamic, and unknown tools.
type ToolAction string

const (
	// ToolActionRead reads files or lists their contents.
	ToolActionRead ToolAction = "read"
	// ToolActionSearch searches files or file contents.
	ToolActionSearch ToolAction = "search"
)

type ToolLocation struct {
	Path string  `json:"path"`
	Line *uint32 `json:"line,omitempty"`
}

type FileChangeKind string

const (
	FileChangeAdd    FileChangeKind = "add"
	FileChangeUpdate FileChangeKind = "update"
	FileChangeDelete FileChangeKind = "delete"
	FileChangeMove   FileChangeKind = "move"
)

// FileChange is a normalized file mutation. Diff supports providers that emit
// unified diffs; OldText/NewText supports ACP-style before/after blocks.
type FileChange struct {
	Path     string         `json:"path"`
	Kind     FileChangeKind `json:"kind,omitempty"`
	Diff     string         `json:"diff,omitempty"`
	OldText  string         `json:"oldText,omitempty"`
	NewText  string         `json:"newText,omitempty"`
	MovePath string         `json:"movePath,omitempty"`
}

// ToolCall is the complete provider-neutral display snapshot for a tool item.
// Adapters merge native sparse updates before emitting it; consumers treat the
// snapshot as immutable. Provider-native input and output blobs stay private to
// adapters and must be normalized into these client-facing fields.
type ToolCall struct {
	// Action is empty unless the provider stated one; see ToolAction.
	Action               ToolAction     `json:"action,omitempty"`
	Name                 string         `json:"name,omitempty"`
	Namespace            string         `json:"namespace,omitempty"`
	ProviderKind         string         `json:"providerKind,omitempty"`
	Command              string         `json:"command,omitempty"`
	Query                string         `json:"query,omitempty"`
	Cwd                  string         `json:"cwd,omitempty"`
	Output               string         `json:"output,omitempty"`
	OutputFormat         OutputFormat   `json:"outputFormat,omitempty"`
	Error                string         `json:"error,omitempty"`
	Locations            []ToolLocation `json:"locations,omitempty"`
	Changes              []FileChange   `json:"changes,omitempty"`
	Attachments          []Attachment   `json:"attachments,omitempty"`
	ExitCode             *int           `json:"exitCode,omitempty"`
	DurationMilliseconds *int64         `json:"durationMilliseconds,omitempty"`
	// Background says the tool runs on as a background task after its
	// result, so its item stays in progress, possibly past its turn, until
	// the task ends. Adapters set it only for tasks they can stop (StopItem).
	Background bool `json:"background,omitempty"`
}

// OutputFormat says how to render tool output. Empty means plain text, such
// as command output.
type OutputFormat string

const OutputFormatMarkdown OutputFormat = "markdown"

// ItemStatus is the provider-neutral lifecycle status of an item.
type ItemStatus string

const (
	ItemStatusInProgress  ItemStatus = "in_progress"
	ItemStatusCompleted   ItemStatus = "completed"
	ItemStatusFailed      ItemStatus = "failed"
	ItemStatusInterrupted ItemStatus = "interrupted"
	ItemStatusDeclined    ItemStatus = "declined"
)

type PlanEntryPriority string

const (
	PlanEntryPriorityHigh   PlanEntryPriority = "high"
	PlanEntryPriorityMedium PlanEntryPriority = "medium"
	PlanEntryPriorityLow    PlanEntryPriority = "low"
)

type PlanEntryStatus string

const (
	PlanEntryStatusPending    PlanEntryStatus = "pending"
	PlanEntryStatusInProgress PlanEntryStatus = "in_progress"
	PlanEntryStatusCompleted  PlanEntryStatus = "completed"
)

// PlanEntry is a provider-neutral execution-plan checklist entry.
type PlanEntry struct {
	Content  string            `json:"content"`
	Priority PlanEntryPriority `json:"priority,omitempty"`
	Status   PlanEntryStatus   `json:"status,omitempty"`
}
