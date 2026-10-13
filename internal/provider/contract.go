// Package provider defines the provider-neutral runtime contract used by the daemon.
//
// Provider adapters translate native protocols, SDKs, desktop app sockets, and
// process protocols into this package. Native SDK/generated DTOs should
// stay inside adapter packages; the rest of the server only sees thread-scoped
// provider sessions, provider turns, and canonical runtime events.
package provider

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"
)

type InstanceID string

type DriverKind string

// RuntimeEventListener receives canonical runtime events from an adapter.
// Adapters call it after converting provider-specific updates into
// provider.RuntimeEvent values.
type RuntimeEventListener func(RuntimeEvent)

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

// ModelSwitchSupport describes whether/how a provider can change the active
// model for a thread.
type ModelSwitchSupport string

const (
	ModelSwitchUnsupported ModelSwitchSupport = "unsupported"
	ModelSwitchInSession   ModelSwitchSupport = "in-session"
)

// PromptContentCapabilities reports which non-text content blocks a provider
// accepts in a turn prompt.
type PromptContentCapabilities struct {
	Image           bool `json:"image,omitempty"`
	Audio           bool `json:"audio,omitempty"`
	EmbeddedContext bool `json:"embeddedContext,omitempty"`
}

// MCPCapabilities reports which MCP transports a provider supports.
type MCPCapabilities struct {
	HTTP bool `json:"http,omitempty"`
	SSE  bool `json:"sse,omitempty"`
}

// Capabilities is the provider-neutral capability set. It advertises ONLY the
// axes that genuinely vary across coding-agent providers; baseline abilities
// (creating sessions, running/interrupting turns, responding to approvals) are
// assumed of every provider and are not listed here. UI clients use these to
// show/hide controls and the server uses them to gate commands.
type Capabilities struct {
	// SessionList reports whether the provider can enumerate existing sessions.
	SessionList bool `json:"sessionList,omitempty"`
	// SessionDelete and SessionClose are advertised independently because ACP
	// agents may support one lifecycle operation without the other.
	SessionDelete bool `json:"sessionDelete,omitempty"`
	SessionClose  bool `json:"sessionClose,omitempty"`
	// LoadReplay reports whether the provider can rebuild display history for a stored session.
	LoadReplay bool `json:"loadReplay,omitempty"`
	// Resume reports whether the provider can restore agent context without
	// replaying display history.
	Resume bool `json:"resume,omitempty"`
	// AdditionalDirectories allows a session to expose more workspace roots in
	// addition to its primary cwd.
	AdditionalDirectories bool `json:"additionalDirectories,omitempty"`
	// Fork is intentionally provider-specific. Stable Codex app-server exposes
	// it; ACP's similarly named operation remains experimental and is not used.
	Fork          bool                      `json:"fork,omitempty"`
	Skills        bool                      `json:"skills,omitempty"`
	Auth          bool                      `json:"auth,omitempty"`
	Logout        bool                      `json:"logout,omitempty"`
	PromptContent PromptContentCapabilities `json:"promptContent,omitzero"`
	ModelSwitch   ModelSwitchSupport        `json:"modelSwitch,omitempty"`
	ConfigOptions bool                      `json:"configOptions,omitempty"`
	MCP           MCPCapabilities           `json:"mcp,omitzero"`
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
	Ask func(context.Context, UserInputRequest) (UserInputAnswer, error) `json:"-"`
}

// UserInputAnswer is the user's response to a UserInputRequest; Answers is
// set when Decision is accept, keyed by Question.ID.
type UserInputAnswer struct {
	Decision ApprovalDecision    `json:"decision"`
	Answers  map[string][]string `json:"answers,omitempty"`
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
	ThreadID string `json:"threadId"`
	Command  string `json:"command"`
	Input    string `json:"input"`
	// Cwd is the thread's workspace, which the daemon resolves.
	Cwd string `json:"-"`
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

// ModelSelection is WHAT a provider instance runs (model + provider-shaped
// options). WHO runs it — the provider instance — is always the separate
// providerInstanceId field wherever a selection travels; the two are never
// duplicated.
type ModelSelection struct {
	Model   string          `json:"model,omitempty"`
	Options json.RawMessage `json:"options,omitempty"`
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

// Session is the provider-neutral session projection returned by a provider
// instance. It is thread-scoped: adapters own any native session identifiers and
// expose only a generic resume cursor when useful. It carries only fields the
// server consumes (session binding + resume cursor); session STATUS is derived
// by orchestration from runtime events, never reported here.
type Session struct {
	Provider           DriverKind `json:"provider"`
	ProviderInstanceID InstanceID `json:"providerInstanceId,omitempty"`
	// Generation identifies the concrete provider process that materialized this
	// session. It is internal fencing metadata, not part of the client contract.
	Generation uint64 `json:"-"`
	// ProviderSessionID identifies this session to the optional provider session-
	// management API. It is retained server-side for binding safety and is never
	// exposed in the thread/session projection.
	ProviderSessionID     string          `json:"-"`
	ProviderName          string          `json:"providerName,omitempty"`
	Cwd                   string          `json:"cwd,omitempty"`
	AdditionalDirectories []string        `json:"additionalDirectories,omitempty"`
	ThreadID              string          `json:"threadId"`
	ResumeCursor          json.RawMessage `json:"resumeCursor,omitempty"`
	// ConfigOptions uses omitzero, not omitempty: provider session snapshots can
	// intentionally report an empty set of provider metadata.
	ConfigOptions []ConfigOption `json:"configOptions,omitzero"`
	Skills        []Skill        `json:"skills,omitzero"`
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

type OptionsSessionCallbacks struct {
	Updated     func([]ConfigOption)
	Invalidated func()
}

type StartSessionInput struct {
	ThreadID           string     `json:"threadId"`
	Provider           DriverKind `json:"provider,omitempty"`
	ProviderInstanceID InstanceID `json:"providerInstanceId,omitempty"`
	// ProviderSessionID is supplied internally when an external session was
	// imported. It is adapter-owned routing data and is never exposed to clients.
	ProviderSessionID     string                  `json:"-"`
	Cwd                   string                  `json:"cwd,omitempty"`
	AdditionalDirectories []string                `json:"additionalDirectories,omitempty"`
	ModelSelection        *ModelSelection         `json:"modelSelection,omitempty"`
	ConfigSelections      []ConfigOptionSelection `json:"configSelections,omitempty"`
	ResumeCursor          json.RawMessage         `json:"resumeCursor,omitempty"`
	// ReplayHistory asks the provider to rebuild display history while restoring
	// the session. On success, StartSessionResult.Replay contains the complete
	// ordered replay batch. A failed start must not expose partial replay events.
	ReplayHistory bool            `json:"replayHistory,omitempty"`
	Options       json.RawMessage `json:"options,omitempty"`
}

// StartSessionResult is the atomic result of preparing a provider session.
// Replay is populated only when ReplayHistory was requested and the provider
// can restore display history. HistoryUnavailable lets orchestration finish a
// degraded restore without confusing an empty history with an unsupported one.
// During a replay start, adapters must include same-thread setup events in
// Replay rather than publishing them to the live event sink before returning.
type StartSessionResult struct {
	Session            Session
	Replay             []RuntimeEvent
	HistoryUnavailable bool
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

type SendTurnInput struct {
	ThreadID string `json:"threadId"`
	TurnID   string `json:"turnId,omitempty"`
	// Steer adds the input to the running turn TurnID instead of starting
	// TurnID. It never starts a turn in its place: a steer whose turn already
	// ended returns ErrTurnNotRunning, and orchestration sends the input as the
	// next turn. Any other error means the provider refused it.
	Steer          bool               `json:"steer,omitempty"`
	Input          string             `json:"input,omitempty"`
	Attachments    []Attachment       `json:"attachments,omitempty"`
	Annotations    []PromptAnnotation `json:"annotations,omitempty"`
	ModelSelection *ModelSelection    `json:"modelSelection,omitempty"`
	Options        json.RawMessage    `json:"options,omitempty"`
	// Presentation and ClientMessageID are local replay bookkeeping, never
	// provider-visible prompt text or client API fields.
	Presentation    *PromptPresentation `json:"-"`
	ClientMessageID string              `json:"-"`
}

// PromptPresentation retains client-owned identity and annotation cards. Text
// is present only when annotations changed the provider-facing prompt; ordinary
// conversation content remains provider-owned.
// ErrTurnNotRunning is returned (wrapped) by SendTurn for a steer whose turn
// is no longer running at the provider.
var ErrTurnNotRunning = errors.New("turn is not running")

type PromptPresentation struct {
	MessageID   string             `json:"messageId"`
	Text        *string            `json:"text,omitempty"`
	Annotations []PromptAnnotation `json:"annotations,omitempty"`
}

type InterruptTurnInput struct {
	ThreadID string `json:"threadId"`
	TurnID   string `json:"turnId,omitempty"`
}

type StopSessionInput struct {
	ThreadID string `json:"threadId"`
}

// StopItemInput stops an item that runs on its own, apart from its turn: a
// tool whose ToolCall.Background is set. The provider then settles the item
// through its usual events.
type StopItemInput struct {
	ThreadID string `json:"threadId"`
	ItemID   string `json:"itemId"`
}

// ForkSessionInput forks the whole native session. Codex app-server also
// accepts a last-turn boundary; it is deliberately not exposed until a client
// surface exists to choose one.
type ForkSessionInput struct {
	ProviderSessionID string `json:"-"`
	// ModelSelection and ConfigSelections are the source session's settings.
	// Providers that keep a fork loaded apply them when creating it.
	ModelSelection   *ModelSelection         `json:"-"`
	ConfigSelections []ConfigOptionSelection `json:"-"`
}

// RenameSessionInput names the native session behind a thread after the
// thread, so the name the user chose in maiD shows in the provider's own
// tools too.
type RenameSessionInput struct {
	ProviderSessionID string `json:"-"`
	Title             string `json:"title"`
}

type ForkSessionResult struct {
	Summary SessionSummary `json:"summary"`
}

type SetConfigOptionInput struct {
	ThreadID string               `json:"threadId"`
	OptionID string               `json:"optionId"`
	Value    any                  `json:"value"`
	Category ConfigOptionCategory `json:"category,omitempty"`
}

type ApprovalDecision string

const (
	ApprovalDecisionAccept           ApprovalDecision = "accept"
	ApprovalDecisionAcceptForSession ApprovalDecision = "acceptForSession"
	ApprovalDecisionDecline          ApprovalDecision = "decline"
	ApprovalDecisionCancel           ApprovalDecision = "cancel"
)

type ApprovalOption struct {
	ID   string `json:"optionId"`
	Name string `json:"name"`
	// Kind uses ACP's permission option kinds for every provider: allow_once,
	// allow_always, reject_once or reject_always.
	Kind string `json:"kind,omitempty"`
}

type RespondToRequestInput struct {
	ThreadID  string           `json:"threadId"`
	RequestID string           `json:"requestId"`
	Decision  ApprovalDecision `json:"decision"`
	// OptionID selects one of the request's advertised ApprovalOptions exactly.
	// When set it takes precedence over Decision, which then only serves as the
	// fallback for providers without option-level responses.
	OptionID string `json:"optionId,omitempty"`
	// Answers answers a user-input request when Decision is accept, keyed by
	// Question.ID. Choice questions answer with option values; other kinds
	// with one entered value.
	Answers map[string][]string `json:"answers,omitempty"`
}

// UserInputRequest is a question an agent asks the user, as opposed to a
// permission request. It either asks Questions (a form) or asks for consent to
// open URL in the browser (for out-of-band flows such as OAuth). Accepting a
// URL request only means the user agreed to open it.
type UserInputRequest struct {
	Message   string     `json:"message"`
	Questions []Question `json:"questions,omitempty"`
	URL       string     `json:"url,omitempty"`
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

type RuntimeEventID string

type RuntimeEventType string

const (
	RuntimeEventThreadMetadataUpdate RuntimeEventType = "thread.metadata.updated"
	RuntimeEventThreadTokenUsage     RuntimeEventType = "thread.token-usage.updated"
	// RuntimeEventThreadGoalUpdated reports the thread's goal: Payload.Goal,
	// or no goal when it is nil. Adapters emit it whenever the goal changes
	// and when a session starts on a thread that may have one.
	RuntimeEventThreadGoalUpdated    RuntimeEventType = "thread.goal.updated"
	RuntimeEventTurnStarted          RuntimeEventType = "turn.started"
	RuntimeEventTurnCompleted        RuntimeEventType = "turn.completed"
	RuntimeEventTurnPlanUpdated      RuntimeEventType = "turn.plan.updated"
	RuntimeEventItemStarted          RuntimeEventType = "item.started"
	RuntimeEventItemUpdated          RuntimeEventType = "item.updated"
	RuntimeEventItemCompleted        RuntimeEventType = "item.completed"
	RuntimeEventContentDelta         RuntimeEventType = "content.delta"
	RuntimeEventRequestOpened        RuntimeEventType = "request.opened"
	RuntimeEventRequestResolved      RuntimeEventType = "request.resolved"
	RuntimeEventRuntimeWarning       RuntimeEventType = "runtime.warning"
	RuntimeEventRuntimeError         RuntimeEventType = "runtime.error"
	RuntimeEventConfigOptionsUpdated RuntimeEventType = "config.options.updated"
)

type RuntimeContentStreamKind string

const (
	RuntimeContentAssistantText RuntimeContentStreamKind = "assistant_text"
	RuntimeContentReasoningText RuntimeContentStreamKind = "reasoning_text"
)

// StopReason says why a completed turn ended early. It is empty when the turn
// finished normally; failures and cancellation are turn states instead.
type StopReason string

const (
	StopReasonMaxTokens       StopReason = "max_tokens"
	StopReasonMaxTurnRequests StopReason = "max_turn_requests"
	StopReasonRefusal         StopReason = "refusal"
)

type RuntimeTurnState string

const (
	RuntimeTurnCompleted   RuntimeTurnState = "completed"
	RuntimeTurnFailed      RuntimeTurnState = "failed"
	RuntimeTurnInterrupted RuntimeTurnState = "interrupted"
	RuntimeTurnCancelled   RuntimeTurnState = "cancelled"
)

type RuntimeRequestType string

const (
	RuntimeRequestCommandExecution RuntimeRequestType = "command_execution_approval"
	RuntimeRequestFileRead         RuntimeRequestType = "file_read_approval"
	RuntimeRequestFileChange       RuntimeRequestType = "file_change_approval"
	RuntimeRequestDynamicToolCall  RuntimeRequestType = "dynamic_tool_call"
)

// ItemKind is the provider-neutral kind of streamed content and thread
// timeline items. Adapters map their native item/update types onto these;
// message kinds are routed into the message pipeline by ingestion while the
// rest become thread timeline items (the things a coding agent does, beyond
// plain messages).
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
)

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

// RuntimeEventPayload is a provider-neutral tagged payload. Structured fields
// cover orchestration and client-visible facts. Args carries opaque approval
// arguments.
type RuntimeEventPayload struct {
	// Internal replay metadata, resolved by the service from exact client IDs.
	ClientMessageID string                   `json:"-"`
	Presentation    *PromptPresentation      `json:"-"`
	TurnState       RuntimeTurnState         `json:"turnState,omitempty"`
	StopReason      StopReason               `json:"stopReason,omitempty"`
	StreamKind      RuntimeContentStreamKind `json:"streamKind,omitempty"`
	Delta           string                   `json:"delta,omitempty"`
	Attachments     []Attachment             `json:"attachments,omitempty"`
	ItemType        ItemKind                 `json:"itemType,omitempty"`
	ItemStatus      ItemStatus               `json:"status,omitempty"`
	RequestType     RuntimeRequestType       `json:"requestType,omitempty"`
	Decision        ApprovalDecision         `json:"decision,omitempty"`
	// Detail is free-form context for the event. On an ItemCompleted event for
	// a reasoning item it carries the provider's full reasoning text, which
	// ingestion treats as authoritative over the streamed deltas.
	Detail     string           `json:"detail,omitempty"`
	Message    string           `json:"message,omitempty"`
	Title      string           `json:"title,omitempty"`
	Options    []ApprovalOption `json:"options,omitempty"`
	Cancelled  bool             `json:"cancelled,omitempty"`
	Args       json.RawMessage  `json:"args,omitempty"`
	Resolution json.RawMessage  `json:"resolution,omitempty"`
	ToolCall   *ToolCall        `json:"toolCall,omitempty"`
	// UserInput makes a request.opened a question instead of a permission
	// request; Answers is set on its request.resolved when the user answered.
	UserInput *UserInputRequest   `json:"userInput,omitempty"`
	Answers   map[string][]string `json:"answers,omitempty"`
	// ConfigOptions/SlashCommands use omitzero, not omitempty: an explicit
	// empty update (non-nil []) must still serialize so consumers clear state.
	ConfigOptions []ConfigOption `json:"configOptions,omitzero"`
	SlashCommands []SlashCommand `json:"slashCommands,omitzero"`
	Skills        []Skill        `json:"skills,omitzero"`
	TokenUsage    *TokenUsage    `json:"tokenUsage,omitempty"`
	PlanEntries   []PlanEntry    `json:"planEntries,omitempty"`
	Goal          *Goal          `json:"goal,omitempty"`
}

// RuntimeEvent is the canonical provider-neutral event emitted by adapters.
type RuntimeEvent struct {
	EventID            RuntimeEventID   `json:"eventId"`
	Type               RuntimeEventType `json:"type"`
	Provider           DriverKind       `json:"provider"`
	ProviderInstanceID InstanceID       `json:"providerInstanceId,omitempty"`
	ProviderName       string           `json:"providerName,omitempty"`
	// Generation identifies the concrete provider process that emitted the
	// event. ProviderService stamps it at the event sink; adapters do not manage
	// it and clients never see it.
	Generation uint64              `json:"-"`
	ThreadID   string              `json:"threadId"`
	TurnID     string              `json:"turnId,omitempty"`
	ItemID     string              `json:"itemId,omitempty"`
	RequestID  string              `json:"requestId,omitempty"`
	CreatedAt  time.Time           `json:"createdAt"`
	Payload    RuntimeEventPayload `json:"payload"`
}
