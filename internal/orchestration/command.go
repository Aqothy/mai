package orchestration

import (
	"encoding/json"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// Commands are CLIENT intents: they are validated by a decider and can be
// rejected or retried (idempotently, by CommandID). Provider/server
// observations are not commands — they enter the log through Engine.AppendEvent.
const (
	CommandThreadCreate          = "thread.create"
	CommandThreadMetaUpdate      = "thread.meta.update"
	CommandThreadTurnStart       = "thread.turn.start"
	CommandThreadTurnInterrupt   = "thread.turn.interrupt"
	CommandThreadApprovalRespond = "thread.approval.respond"
	CommandThreadSessionPrepare  = "thread.session.prepare"
	CommandThreadSessionStop     = "thread.session.stop"
	CommandThreadConfigOptionSet = "thread.config-option.set"
)

type Command struct {
	Type               string                    `json:"type"`
	CommandID          CommandID                 `json:"commandId,omitempty"`
	ThreadID           ThreadID                  `json:"threadId,omitempty"`
	TurnID             TurnID                    `json:"turnId,omitempty"`
	Title              string                    `json:"title,omitempty"`
	ProviderInstanceID provider.InstanceID       `json:"providerInstanceId,omitempty"`
	Cwd                string                    `json:"cwd,omitempty"`
	ModelSelection     *provider.ModelSelection  `json:"modelSelection,omitempty"`
	Message            *CommandMessage           `json:"message,omitempty"`
	RequestID          ApprovalID                `json:"requestId,omitempty"`
	Decision           provider.ApprovalDecision `json:"decision,omitempty"`
	OptionID           string                    `json:"optionId,omitempty"`
	Value              any                       `json:"value,omitempty"`
	CreatedAt          time.Time                 `json:"createdAt,omitzero"`
}

type CommandMessage struct {
	MessageID   string                `json:"messageId,omitempty"`
	Role        MessageRole           `json:"role,omitempty"`
	Text        string                `json:"text"`
	Attachments []provider.Attachment `json:"attachments,omitempty"`
	Raw         json.RawMessage       `json:"raw,omitempty"`
}

// DispatchResult is the receipt returned for a dispatched command: the
// sequence of the event it appended.
type DispatchResult struct {
	Sequence uint64 `json:"sequence"`
}
