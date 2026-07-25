package orchestration

import (
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// CommandType is an alias, not a defined type: Command.Type stays a plain string
// so an unknown type reaches the dispatch switch's default and is rejected
// there rather than failing to decode. The alias marks the constants below as
// one closed vocabulary for api/wire's coverage test.
type CommandType = string

// Commands are CLIENT intents: they are validated by a decider and can be
// rejected or retried (idempotently, by CommandID). Provider/server
// observations are not commands — they enter the log through Engine.AppendEvent.
const (
	CommandThreadCreate          CommandType = "thread.create"
	CommandThreadStart           CommandType = "thread.start"
	CommandThreadMetaUpdate      CommandType = "thread.meta.update"
	CommandThreadTurnStart       CommandType = "thread.turn.start"
	CommandThreadTurnRetry       CommandType = "thread.turn.retry"
	CommandThreadTurnInterrupt   CommandType = "thread.turn.interrupt"
	CommandThreadApprovalRespond CommandType = "thread.approval.respond"
	CommandThreadSessionPrepare  CommandType = "thread.session.prepare"
	CommandThreadSessionStop     CommandType = "thread.session.stop"
	CommandThreadConfigOptionSet CommandType = "thread.config-option.set"
)

type Command struct {
	Type               string                           `json:"type"`
	CommandID          CommandID                        `json:"commandId,omitempty"`
	ThreadID           ThreadID                         `json:"threadId,omitempty"`
	TurnID             TurnID                           `json:"turnId,omitempty"`
	Title              string                           `json:"title,omitempty"`
	ProviderInstanceID provider.InstanceID              `json:"providerInstanceId,omitempty"`
	Cwd                string                           `json:"cwd,omitempty"`
	ModelSelection     *provider.ModelSelection         `json:"modelSelection,omitempty"`
	Message            *CommandMessage                  `json:"message,omitempty"`
	RequestID          ApprovalID                       `json:"requestId,omitempty"`
	Decision           provider.ApprovalDecision        `json:"decision,omitempty"`
	OptionID           string                           `json:"optionId,omitempty"`
	Value              any                              `json:"value,omitempty"`
	ConfigSelections   []provider.ConfigOptionSelection `json:"configSelections,omitempty"`
	CreatedAt          time.Time                        `json:"createdAt,omitzero"`
}

// CommandMessage is the prompt a client sends with thread.start/thread.turn.start.
// It carries no role: a client-authored message is always a user message, and
// the engine stamps MessageRoleUser itself.
type CommandMessage struct {
	MessageID   string                `json:"messageId,omitempty"`
	Text        string                `json:"text"`
	Attachments []provider.Attachment `json:"attachments,omitempty"`
}

// DispatchResult is the receipt returned for a dispatched command: the
// sequence of the event it appended.
type DispatchResult struct {
	Sequence uint64 `json:"sequence"`
}
