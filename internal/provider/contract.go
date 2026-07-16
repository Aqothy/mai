// Package provider defines the provider-neutral runtime contract used by the daemon.
//
// Provider adapters translate native protocols, SDKs, desktop app sockets, and
// process protocols into this package. Native SDK/generated DTOs should
// stay inside adapter packages; the rest of the server only sees thread-scoped
// provider sessions, provider turns, and canonical runtime events.
package provider

import (
	"encoding/json"
	"fmt"
	"time"
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
	// LoadReplay reports whether the provider can rebuild display history for a stored session.
	LoadReplay bool `json:"loadReplay,omitempty"`
	// Resume reports whether the provider can restore agent context without
	// replaying display history.
	Resume        bool                      `json:"resume,omitempty"`
	Auth          bool                      `json:"auth,omitempty"`
	Logout        bool                      `json:"logout,omitempty"`
	PromptContent PromptContentCapabilities `json:"promptContent,omitzero"`
	ModelSwitch   ModelSwitchSupport        `json:"modelSwitch,omitempty"`
	MCP           MCPCapabilities           `json:"mcp,omitzero"`
}

type AuthStatus string

const (
	AuthStatusUnknown         AuthStatus = "unknown"
	AuthStatusAuthenticated   AuthStatus = "authenticated"
	AuthStatusUnauthenticated AuthStatus = "unauthenticated"
)

type AuthMethod struct {
	ID          string `json:"id"`
	Name        string `json:"name,omitempty"`
	Description string `json:"description,omitempty"`
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
	InstanceID    InstanceID                 `json:"instanceId"`
	Name          string                     `json:"name"`
	Driver        DriverKind                 `json:"driver"`
	PID           int                        `json:"pid,omitempty"`
	Status        InstanceStatus             `json:"status"`
	StartedAt     time.Time                  `json:"startedAt"`
	InitializedAt time.Time                  `json:"initializedAt"`
	Capabilities  Capabilities               `json:"capabilities"`
	Auth          Auth                       `json:"auth"`
	Metadata      map[string]json.RawMessage `json:"metadata,omitempty"`
}

// SlashCommand is an agent-advertised command the client can offer (ACP
// available_commands_update).
type SlashCommand struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	HasInput    bool   `json:"hasInput,omitempty"`
}

type TokenUsage struct {
	UsedTokens int     `json:"usedTokens"`
	MaxTokens  int     `json:"maxTokens,omitempty"`
	Cost       float64 `json:"cost,omitempty"`
	Currency   string  `json:"currency,omitempty"`
}

type SessionSummary struct {
	SessionID string `json:"sessionId"`
	Title     string `json:"title,omitempty"`
	Cwd       string `json:"cwd,omitempty"`
	UpdatedAt string `json:"updatedAt,omitempty"`
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
	Value string `json:"value"`
	Label string `json:"label,omitempty"`
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
	ProviderSessionID string          `json:"-"`
	ProviderName      string          `json:"providerName,omitempty"`
	Cwd               string          `json:"cwd,omitempty"`
	ThreadID          string          `json:"threadId"`
	ResumeCursor      json.RawMessage `json:"resumeCursor,omitempty"`
	// ConfigOptions uses omitzero, not omitempty: provider session snapshots can
	// intentionally report an empty set of provider metadata.
	ConfigOptions []ConfigOption `json:"configOptions,omitzero"`
}

type ConfigOptionSelection struct {
	OptionID string               `json:"optionId"`
	Value    any                  `json:"value"`
	Category ConfigOptionCategory `json:"category,omitempty"`
}

type StartSessionInput struct {
	ThreadID           string     `json:"threadId"`
	Provider           DriverKind `json:"provider,omitempty"`
	ProviderInstanceID InstanceID `json:"providerInstanceId,omitempty"`
	// ProviderSessionID is supplied internally when an external session was
	// imported. It is adapter-owned routing data and is never exposed to clients.
	ProviderSessionID string                  `json:"-"`
	Cwd               string                  `json:"cwd,omitempty"`
	ModelSelection    *ModelSelection         `json:"modelSelection,omitempty"`
	ConfigSelections  []ConfigOptionSelection `json:"configSelections,omitempty"`
	ResumeCursor      json.RawMessage         `json:"resumeCursor,omitempty"`
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

type Attachment struct {
	Kind     string                     `json:"kind"`
	Name     string                     `json:"name,omitempty"`
	MimeType string                     `json:"mimeType,omitempty"`
	Data     string                     `json:"data,omitempty"`
	URI      string                     `json:"uri,omitempty"`
	Metadata map[string]json.RawMessage `json:"metadata,omitempty"`
	Raw      json.RawMessage            `json:"raw,omitempty"`
}

type SendTurnInput struct {
	ThreadID       string          `json:"threadId"`
	TurnID         string          `json:"turnId,omitempty"`
	Input          string          `json:"input,omitempty"`
	Attachments    []Attachment    `json:"attachments,omitempty"`
	ModelSelection *ModelSelection `json:"modelSelection,omitempty"`
	Options        json.RawMessage `json:"options,omitempty"`
}

type InterruptTurnInput struct {
	ThreadID string `json:"threadId"`
	TurnID   string `json:"turnId,omitempty"`
}

type StopSessionInput struct {
	ThreadID string `json:"threadId"`
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
	ID       string                     `json:"optionId"`
	Name     string                     `json:"name"`
	Kind     string                     `json:"kind,omitempty"`
	Metadata map[string]json.RawMessage `json:"metadata,omitempty"`
	Raw      json.RawMessage            `json:"raw,omitempty"`
}

type RespondToRequestInput struct {
	ThreadID  string           `json:"threadId"`
	RequestID string           `json:"requestId"`
	Decision  ApprovalDecision `json:"decision"`
	// OptionID selects one of the request's advertised ApprovalOptions exactly.
	// When set it takes precedence over Decision, which then only serves as the
	// fallback for providers without option-level responses.
	OptionID string `json:"optionId,omitempty"`
}

type RuntimeEventID string

type RuntimeEventType string

const (
	RuntimeEventThreadMetadataUpdate RuntimeEventType = "thread.metadata.updated"
	RuntimeEventThreadTokenUsage     RuntimeEventType = "thread.token-usage.updated"
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
	ItemKindUserMessage      ItemKind = "user_message"
	ItemKindAssistantMessage ItemKind = "assistant_message"
	ItemKindReasoning        ItemKind = "reasoning"
	ItemKindCommandExecution ItemKind = "command_execution"
	ItemKindFileChange       ItemKind = "file_change"
	ItemKindMCPToolCall      ItemKind = "mcp_tool_call"
	ItemKindToolCall         ItemKind = "tool_call"
	ItemKindWarning          ItemKind = "warning"
	ItemKindError            ItemKind = "error"
)

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
// cover the orchestration-relevant facts; provider-specific details travel in
// Args/Data without becoming part of the server interface.
type RuntimeEventPayload struct {
	TurnState   RuntimeTurnState         `json:"turnState,omitempty"`
	StopReason  string                   `json:"stopReason,omitempty"`
	StreamKind  RuntimeContentStreamKind `json:"streamKind,omitempty"`
	Delta       string                   `json:"delta,omitempty"`
	Attachments []Attachment             `json:"attachments,omitempty"`
	ItemType    ItemKind                 `json:"itemType,omitempty"`
	ItemStatus  ItemStatus               `json:"status,omitempty"`
	RequestType RuntimeRequestType       `json:"requestType,omitempty"`
	Decision    ApprovalDecision         `json:"decision,omitempty"`
	Detail      string                   `json:"detail,omitempty"`
	Message     string                   `json:"message,omitempty"`
	Title       string                   `json:"title,omitempty"`
	Options     []ApprovalOption         `json:"options,omitempty"`
	Cancelled   bool                     `json:"cancelled,omitempty"`
	Args        json.RawMessage          `json:"args,omitempty"`
	Resolution  json.RawMessage          `json:"resolution,omitempty"`
	Data        json.RawMessage          `json:"data,omitempty"`
	// ConfigOptions/SlashCommands use omitzero, not omitempty: an explicit
	// empty update (non-nil []) must still serialize so consumers clear state.
	ConfigOptions []ConfigOption             `json:"configOptions,omitzero"`
	SlashCommands []SlashCommand             `json:"slashCommands,omitzero"`
	TokenUsage    *TokenUsage                `json:"tokenUsage,omitempty"`
	PlanEntries   []PlanEntry                `json:"planEntries,omitempty"`
	Metadata      map[string]json.RawMessage `json:"metadata,omitempty"`
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
