package orchestration

import (
	"encoding/json"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

type ThreadID string
type TurnID string
type MessageID string
type ApprovalID string
type EventID string
type CommandID string

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
	ID                 ThreadID                 `json:"id"`
	Draft              bool                     `json:"draft"`
	Title              string                   `json:"title"`
	ProviderInstanceID provider.InstanceID      `json:"providerInstanceId,omitempty"`
	ModelSelection     *provider.ModelSelection `json:"modelSelection,omitempty"`
	Cwd                string                   `json:"cwd,omitempty"`
	Session            *SessionBinding          `json:"session,omitempty"`
	LatestTurn         *Turn                    `json:"latestTurn,omitempty"`
	// Timeline is the canonical conversation order. New entries append; updates
	// mutate their existing entry without moving it.
	Timeline  Timeline  `json:"timeline"`
	Plan      *Plan     `json:"plan,omitempty"`
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
}

type Turn struct {
	ID                 TurnID     `json:"turnId"`
	State              TurnState  `json:"state"`
	RequestedAt        time.Time  `json:"requestedAt"`
	StartedAt          *time.Time `json:"startedAt,omitempty"`
	CompletedAt        *time.Time `json:"completedAt,omitempty"`
	StopReason         string     `json:"stopReason,omitempty"`
	Error              string     `json:"error,omitempty"`
	InterruptRequested bool       `json:"interruptRequested,omitempty"`
}

type Message struct {
	ID          MessageID             `json:"id"`
	Role        MessageRole           `json:"role"`
	Text        string                `json:"text"`
	Attachments []provider.Attachment `json:"attachments,omitempty"`
	TurnID      TurnID                `json:"turnId,omitempty"`
	CreatedAt   time.Time             `json:"createdAt"`
	UpdatedAt   time.Time             `json:"updatedAt"`
}

type Approval struct {
	RequestID string                    `json:"requestId"`
	TurnID    TurnID                    `json:"turnId,omitempty"`
	Args      json.RawMessage           `json:"args,omitempty"`
	Options   []provider.ApprovalOption `json:"options,omitempty"`
	Status    ApprovalStatus            `json:"status"`
	Decision  provider.ApprovalDecision `json:"decision,omitempty"`
	OptionID  string                    `json:"optionId,omitempty"`
	CreatedAt time.Time                 `json:"createdAt"`
	UpdatedAt time.Time                 `json:"updatedAt"`
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
	ProviderGeneration uint64              `json:"-"`
	ProviderName       string              `json:"providerName,omitempty"`
	Provider           provider.DriverKind `json:"provider,omitempty"`
	Cwd                string              `json:"cwd,omitempty"`
	Status             SessionStatus       `json:"status"`
	ActiveTurnID       TurnID              `json:"activeTurnId,omitempty"`
	StopRequested      bool                `json:"stopRequested,omitempty"`
	// ConfigOptions/SlashCommands use omitzero, not omitempty: snapshots must
	// preserve explicit empty lists after provider metadata is cleared.
	ConfigOptions []provider.ConfigOption `json:"configOptions,omitzero"`
	SlashCommands []provider.SlashCommand `json:"slashCommands,omitzero"`
	TokenUsage    *provider.TokenUsage    `json:"tokenUsage,omitempty"`
	LastError     string                  `json:"lastError,omitempty"`
	UpdatedAt     time.Time               `json:"updatedAt"`
}

// Item is one entry in a thread's non-message timeline (tool calls, reasoning,
// warnings, errors). It is upserted by ID across its lifecycle.
type Item struct {
	ID     string              `json:"id"`
	Kind   provider.ItemKind   `json:"kind"`
	Title  string              `json:"title,omitempty"`
	Status provider.ItemStatus `json:"status"`
	// Payload is provider-shaped JSON, applied by REPLACEMENT: a non-empty
	// payload on an item event is the item's complete new payload; an absent
	// one keeps the previous payload (CLIENT_API §5).
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
