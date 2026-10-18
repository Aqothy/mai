package orchestration

import (
	"encoding/json"
	"slices"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

type ThreadID string
type TurnID string
type MessageID string
type ApprovalID string
type EventID string
type CommandID string

// NewThreadID mints a server-owned thread id for imported provider sessions.
func NewThreadID() ThreadID { return ThreadID(newID("thread")) }

type MessageRole string

const (
	MessageRoleUser      MessageRole = "user"
	MessageRoleAssistant MessageRole = "assistant"
)

type TurnState string

const (
	TurnStateRunning     TurnState = "running"
	TurnStateInterrupted TurnState = "interrupted"
	TurnStateCompleted   TurnState = "completed"
	TurnStateError       TurnState = "error"
)

type SessionStatus string

const (
	SessionStatusStarting    SessionStatus = "starting"
	SessionStatusRunning     SessionStatus = "running"
	SessionStatusReady       SessionStatus = "ready"
	SessionStatusInterrupted SessionStatus = "interrupted"
	SessionStatusStopped     SessionStatus = "stopped"
	SessionStatusError       SessionStatus = "error"
)

type ApprovalStatus string

const (
	ApprovalStatusPending  ApprovalStatus = "pending"
	ApprovalStatusResolved ApprovalStatus = "resolved"
)

type Thread struct {
	ID ThreadID `json:"id"`
	// ReplayHistoryPending is internal restart state. Restored threads consume
	// it only after the provider's history replay has been fully ingested.
	ReplayHistoryPending  bool                             `json:"-"`
	Title                 string                           `json:"title"`
	ProviderInstanceID    provider.InstanceID              `json:"providerInstanceId,omitempty"`
	ModelSelection        *provider.ModelSelection         `json:"modelSelection,omitempty"`
	ConfigSelections      []provider.ConfigOptionSelection `json:"-"`
	Cwd                   string                           `json:"cwd,omitempty"`
	AdditionalDirectories []string                         `json:"additionalDirectories,omitempty"`
	Session               *SessionBinding                  `json:"session,omitempty"`
	LatestTurn            *Turn                            `json:"latestTurn,omitempty"`
	// PreviousTurns are the thread's earlier turns, oldest first, with their
	// final outcome and timing. LatestTurn is not repeated here.
	PreviousTurns []Turn `json:"previousTurns,omitempty"`
	// Timeline is the canonical conversation order. New entries append; updates
	// mutate their existing entry without moving it.
	Timeline Timeline `json:"timeline"`
	// QueuedPrompts wait, in order, for the thread to take its next turn. A
	// prompt is either queued or a timeline message, never both.
	QueuedPrompts []QueuedPrompt `json:"queuedPrompts,omitempty"`
	// QueueHeld pauses the queue after the user stops a turn or a turn fails,
	// so waiting prompts don't run into the same stop or failure. Sending or
	// retrying releases it. It is only ever set while prompts wait.
	QueueHeld bool `json:"-"`
	// MissedSteers are messages whose steer arrived after its turn ended at
	// the provider. Like a message sent just then, each starts the next turn.
	MissedSteers []MessageID `json:"-"`
	Plan         *Plan       `json:"plan,omitempty"`
	CreatedAt    time.Time   `json:"createdAt"`
	// UpdatedAt is the sidebar recency timestamp: the latest user-message time,
	// or CreatedAt before the first user message.
	UpdatedAt time.Time `json:"updatedAt"`
	// pendingApprovals are the timeline's pending approvals, oldest first, so
	// the sidebar badge and the session lifecycle never scan the timeline.
	// Only the projection's approval opened/resolved handlers change it.
	pendingApprovals []*Approval
}

type Turn struct {
	ID                 TurnID              `json:"turnId"`
	State              TurnState           `json:"state"`
	RequestedAt        time.Time           `json:"requestedAt"`
	StartedAt          *time.Time          `json:"startedAt,omitempty"`
	CompletedAt        *time.Time          `json:"completedAt,omitempty"`
	StopReason         provider.StopReason `json:"stopReason,omitempty"`
	Error              string              `json:"error,omitempty"`
	InterruptRequested bool                `json:"interruptRequested,omitempty"`
}

type Message struct {
	ID          MessageID                   `json:"id"`
	Role        MessageRole                 `json:"role"`
	Text        string                      `json:"text"`
	Attachments []provider.Attachment       `json:"attachments,omitempty"`
	Annotations []provider.PromptAnnotation `json:"annotations,omitempty"`
	TurnID      TurnID                      `json:"turnId,omitempty"`
	// Delivery is empty once the provider has the message. DeliveryError is
	// the reason a message was not delivered.
	Delivery      MessageDelivery `json:"delivery,omitempty"`
	DeliveryError string          `json:"deliveryError,omitempty"`
	CreatedAt     time.Time       `json:"createdAt"`
	UpdatedAt     time.Time       `json:"updatedAt"`
}

// MessageDelivery tracks a user message on its way to the provider.
type MessageDelivery string

const (
	MessageSending      MessageDelivery = "sending"
	MessageNotDelivered MessageDelivery = "not-delivered"
)

// QueuedPrompt is a prompt sent while the thread was busy. The engine sends
// the first one when the running turn ends; until then the user can remove
// it, steer it into the running turn, or send it once the thread is idle.
type QueuedPrompt struct {
	MessageID   MessageID                   `json:"messageId"`
	Text        string                      `json:"text"`
	Attachments []provider.Attachment       `json:"attachments,omitempty"`
	Annotations []provider.PromptAnnotation `json:"annotations,omitempty"`
	CreatedAt   time.Time                   `json:"createdAt"`
}

func (thread *Thread) queuedPrompt(messageID MessageID) *QueuedPrompt {
	index := slices.IndexFunc(thread.QueuedPrompts, func(prompt QueuedPrompt) bool { return prompt.MessageID == messageID })
	if index < 0 {
		return nil
	}
	return &thread.QueuedPrompts[index]
}

type Approval struct {
	RequestID string                    `json:"requestId"`
	TurnID    TurnID                    `json:"turnId,omitempty"`
	Args      json.RawMessage           `json:"args,omitempty"`
	Options   []provider.ApprovalOption `json:"options,omitempty"`
	Status    ApprovalStatus            `json:"status"`
	Decision  provider.ApprovalDecision `json:"decision,omitempty"`
	OptionID  string                    `json:"optionId,omitempty"`
	// UserInput is set when the agent asks the user a question rather than
	// for permission; Answers holds what the user submitted.
	UserInput *provider.UserInputRequest `json:"userInput,omitempty"`
	Answers   map[string][]string        `json:"answers,omitempty"`
	CreatedAt time.Time                  `json:"createdAt"`
	UpdatedAt time.Time                  `json:"updatedAt"`
}

// SessionBinding is orchestration's view of the provider session for a thread.
// It deliberately does NOT hold native resume cursors — that lives at the
// provider layer. It carries the provider-advertised config options so a UI can
// render model/mode/reasoning selectors.
type SessionBinding struct {
	ThreadID           ThreadID            `json:"threadId"`
	ProviderInstanceID provider.InstanceID `json:"providerInstanceId"`
	// ProviderGeneration fences events from a replaced process that reused the
	// same provider instance and turn ids. It is server-internal projection state.
	ProviderGeneration    uint64              `json:"-"`
	ProviderName          string              `json:"providerName,omitempty"`
	Driver                provider.DriverKind `json:"driver,omitempty"`
	Cwd                   string              `json:"cwd,omitempty"`
	AdditionalDirectories []string            `json:"additionalDirectories,omitempty"`
	Status                SessionStatus       `json:"status"`
	ActiveTurnID          TurnID              `json:"activeTurnId,omitempty"`
	StopRequested         bool                `json:"stopRequested,omitempty"`
	// ConfigOptions/SlashCommands use omitzero, not omitempty: snapshots must
	// preserve explicit empty lists after provider metadata is cleared.
	ConfigOptions []provider.ConfigOption `json:"configOptions,omitzero"`
	SlashCommands []provider.SlashCommand `json:"slashCommands,omitzero"`
	Skills        []provider.Skill        `json:"skills,omitzero"`
	TokenUsage    *provider.TokenUsage    `json:"tokenUsage,omitempty"`
	// Goal is the goal the provider pursues in this session, if any.
	Goal      *provider.Goal `json:"goal,omitempty"`
	LastError string         `json:"lastError,omitempty"`
	UpdatedAt time.Time      `json:"updatedAt"`
}

// Item is one entry in a thread's non-message timeline (tool calls, reasoning,
// warnings, errors). It is upserted by ID across its lifecycle.
type Item struct {
	ID              string              `json:"id"`
	Kind            provider.ItemKind   `json:"kind"`
	Title           string              `json:"title,omitempty"`
	Status          provider.ItemStatus `json:"status"`
	DetailAvailable bool                `json:"detailAvailable,omitempty"`
	ToolCallSummary *ToolCallSummary    `json:"toolCallSummary,omitempty"`
	// Sequence is the event sequence of the latest upsert and is the stable key
	// for cached item details.
	Sequence uint64 `json:"sequence,omitempty"`
	// ToolCall is a complete provider-neutral snapshot. An absent value on an
	// update preserves the prior snapshot; adapters merge native sparse updates.
	ToolCall *provider.ToolCall `json:"toolCall,omitempty"`
	// Payload is orchestration-owned display JSON for non-tool items such as
	// reasoning, warnings, and errors. It is applied by replacement.
	Payload json.RawMessage `json:"payload,omitempty"`
	// TextDelta is an EVENT-ONLY field (coalesced reasoning chunks): when set,
	// the chunk is appended to the payload's "text" instead of the payload
	// being replaced, keeping flushed events O(chunk). It is never stored on
	// the projected item.
	TextDelta string    `json:"textDelta,omitempty"`
	TurnID    TurnID    `json:"turnId,omitempty"`
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
}

// ToolCallSummary is the bounded, client-facing representation carried by
// thread snapshots and live item events. Complete tool data remains in the
// server projection and is available through orchestration.getItemDetail.
type ToolCallSummary struct {
	Action               provider.ToolAction     `json:"action,omitempty"`
	Name                 string                  `json:"name,omitempty"`
	Namespace            string                  `json:"namespace,omitempty"`
	ProviderKind         string                  `json:"providerKind,omitempty"`
	CommandPreview       string                  `json:"commandPreview,omitempty"`
	QueryPreview         string                  `json:"queryPreview,omitempty"`
	Cwd                  string                  `json:"cwd,omitempty"`
	OutputPreview        string                  `json:"outputPreview,omitempty"`
	OutputFormat         provider.OutputFormat   `json:"outputFormat,omitempty"`
	ErrorPreview         string                  `json:"errorPreview,omitempty"`
	Locations            []provider.ToolLocation `json:"locations,omitempty"`
	LocationCount        int                     `json:"locationCount,omitempty"`
	Changes              []FileChangeSummary     `json:"changes,omitempty"`
	ChangeCount          int                     `json:"changeCount,omitempty"`
	Attachments          []ToolAttachmentSummary `json:"attachments,omitempty"`
	AttachmentCount      int                     `json:"attachmentCount,omitempty"`
	ExitCode             *int                    `json:"exitCode,omitempty"`
	DurationMilliseconds *int64                  `json:"durationMilliseconds,omitempty"`
	// Background mirrors ToolCall.Background: while the item runs, clients
	// offer to stop it (thread.item.stop).
	Background bool `json:"background,omitempty"`
	Truncated  bool `json:"truncated,omitempty"`
}

// FileChangeSummary deliberately excludes diff/oldText/newText.
type FileChangeSummary struct {
	Path     string                  `json:"path"`
	Kind     provider.FileChangeKind `json:"kind,omitempty"`
	MovePath string                  `json:"movePath,omitempty"`
}

// ToolAttachmentSummary excludes inline attachment data while retaining
// enough metadata to describe the result before full details are requested.
type ToolAttachmentSummary struct {
	Kind     provider.AttachmentKind `json:"kind"`
	Name     string                  `json:"name,omitempty"`
	MimeType string                  `json:"mimeType,omitempty"`
	URI      string                  `json:"uri,omitempty"`
}

type TimelineEntryKind string

const (
	TimelineEntryMessage  TimelineEntryKind = "message"
	TimelineEntryItem     TimelineEntryKind = "item"
	TimelineEntryApproval TimelineEntryKind = "approval"
)

// TimelineEntry is a tagged union. Exactly one payload matching Kind is set;
// its slice position is its stable conversation position.
type TimelineEntry struct {
	Kind     TimelineEntryKind `json:"kind"`
	Message  *Message          `json:"message,omitempty"`
	Item     *Item             `json:"item,omitempty"`
	Approval *Approval         `json:"approval,omitempty"`
}

// Plan is the live execution checklist for a thread (ACP `session/update` plan,
// Codex/Claude todo lists). It is fully replaced on each update.
type Plan struct {
	Entries   []provider.PlanEntry `json:"entries"`
	UpdatedAt time.Time            `json:"updatedAt"`
}
