package orchestration

import (
	"encoding/json"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

type EventType string

const (
	EventThreadCreated                     EventType = "thread.created"
	EventThreadMetaUpdated                 EventType = "thread.meta-updated"
	EventThreadMessageSent                 EventType = "thread.message-sent"
	EventThreadTurnStartRequested          EventType = "thread.turn-start-requested"
	EventThreadTurnInterruptRequested      EventType = "thread.turn-interrupt-requested"
	EventThreadTurnInterruptConfirmed      EventType = "thread.turn-interrupt-confirmed"
	EventThreadTurnInterruptFailed         EventType = "thread.turn-interrupt-failed"
	EventThreadApprovalResponseRequested   EventType = "thread.approval-response-requested"
	EventThreadSessionStopRequested        EventType = "thread.session-stop-requested"
	EventThreadSessionStopFailed           EventType = "thread.session-stop-failed"
	EventThreadRuntimeModeSet              EventType = "thread.runtime-mode-set"
	EventThreadInteractionModeSetRequested EventType = "thread.interaction-mode-set-requested"
	EventThreadInteractionModeSet          EventType = "thread.interaction-mode-set"
	EventThreadConfigOptionSetRequested    EventType = "thread.config-option-set-requested"
	EventThreadSessionStatusSet            EventType = "thread.session-status-set"
	EventThreadItemUpserted                EventType = "thread.item-upserted"
	EventThreadPlanUpdated                 EventType = "thread.plan-updated"
	EventThreadApprovalOpened              EventType = "thread.approval-opened"
	EventThreadApprovalResolved            EventType = "thread.approval-resolved"
	EventThreadConfigOptionsUpdated        EventType = "thread.config-options-updated"
	EventThreadSlashCommandsUpdated        EventType = "thread.slash-commands-updated"
	EventThreadTokenUsageUpdated           EventType = "thread.token-usage-updated"
)

type ActorKind string

const (
	ActorKindClient   ActorKind = "client"
	ActorKindServer   ActorKind = "server"
	ActorKindProvider ActorKind = "provider"
)

type Event struct {
	Sequence   uint64        `json:"sequence"`
	EventID    EventID       `json:"eventId"`
	Type       EventType     `json:"type"`
	OccurredAt time.Time     `json:"occurredAt"`
	CommandID  CommandID     `json:"commandId,omitempty"`
	Actor      ActorKind     `json:"actor,omitempty"`
	Metadata   EventMetadata `json:"metadata,omitzero"`
	Payload    EventPayload  `json:"payload"`
}

type EventMetadata struct {
	RequestID string `json:"requestId,omitempty"`
}

// EventPayload is an envelope with typed optional sections: scalar head fields
// for lifecycle/meta events plus pointer/slice sections (Item, Plan, Approval,
// ConfigOptions) for the richer projections.
type EventPayload struct {
	ThreadID           ThreadID                 `json:"threadId,omitempty"`
	Title              string                   `json:"title,omitempty"`
	ProviderInstanceID provider.InstanceID      `json:"providerInstanceId,omitempty"`
	ModelSelection     *provider.ModelSelection `json:"modelSelection,omitempty"`
	RuntimeMode        RuntimeMode              `json:"runtimeMode,omitempty"`
	InteractionMode    ProviderInteractionMode  `json:"interactionMode,omitempty"`
	Cwd                string                   `json:"cwd,omitempty"`
	Session            *SessionBinding          `json:"session,omitempty"`
	SessionCleared     bool                     `json:"sessionCleared,omitempty"`
	MessageID          MessageID                `json:"messageId,omitempty"`
	Role               MessageRole              `json:"role,omitempty"`
	Text               string                   `json:"text,omitempty"`
	Attachments        []provider.Attachment    `json:"attachments,omitempty"`
	TurnID             TurnID                   `json:"turnId,omitempty"`
	// StopReason is the provider's reason a turn settled (end_turn, max_tokens,
	// refusal, ...), carried on session-status-set settle events so clients can
	// surface latestTurn.stopReason.
	StopReason string `json:"stopReason,omitempty"`
	// Steering records that a turn-start command was accepted against an
	// already-running turn. It is internal reactor metadata, not a wire field.
	Steering  bool                      `json:"-"`
	CreatedAt time.Time                 `json:"createdAt,omitzero"`
	UpdatedAt time.Time                 `json:"updatedAt,omitzero"`
	RequestID ApprovalID                `json:"requestId,omitempty"`
	Decision  provider.ApprovalDecision `json:"decision,omitempty"`
	OptionID  string                    `json:"optionId,omitempty"`
	Value     any                       `json:"value,omitempty"`
	Item      *Item                     `json:"item,omitempty"`
	Plan      *Plan                     `json:"plan,omitempty"`
	Approval  *ApprovalEvent            `json:"approval,omitempty"`
	// ConfigOptions/SlashCommands use omitzero, not omitempty: an explicit
	// empty update (non-nil []) must still serialize so clients clear state.
	ConfigOptions []provider.ConfigOption `json:"configOptions,omitzero"`
	SlashCommands []provider.SlashCommand `json:"slashCommands,omitzero"`
	TokenUsage    *provider.TokenUsage    `json:"tokenUsage,omitempty"`
}

// ThreadID names the thread an event belongs to. Every event constructor
// stamps Payload.ThreadID; all current events are thread-scoped.
func (e Event) ThreadID() ThreadID {
	return e.Payload.ThreadID
}

// ApprovalEvent carries the data for thread.approval.open / thread.approval.resolve.
type ApprovalEvent struct {
	RequestID   string                      `json:"requestId"`
	TurnID      TurnID                      `json:"turnId,omitempty"`
	RequestType provider.RuntimeRequestType `json:"requestType,omitempty"`
	Args        json.RawMessage             `json:"args,omitempty"`
	Options     []provider.ApprovalOption   `json:"options,omitempty"`
	Detail      string                      `json:"detail,omitempty"`
	Decision    provider.ApprovalDecision   `json:"decision,omitempty"`
	OptionID    string                      `json:"optionId,omitempty"`
	Cancelled   bool                        `json:"cancelled,omitempty"`
}

func marshalEventPayload(value any) json.RawMessage {
	raw, _ := json.Marshal(value)
	return raw
}
