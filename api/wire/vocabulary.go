package wire

import (
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/terminal"
)

// Vocabularies registers the closed string vocabularies clients branch on. The
// JSON Schema reflector only sees `string` for Go named-string constants, so
// without this every client re-types the literals by hand.
//
// Entries reference the constants directly: renaming a value propagates,
// deleting one fails the build, and vocabulary_test.go catches additions.
// Server-internal vocabularies do not belong here.
var Vocabularies = []VocabularyDefinition{
	{
		Name:        "EventType",
		Description: "Type discriminator of a thread event delivered on orchestration.subscribeThread.",
		Values: []string{
			string(orchestration.EventThreadCreated),
			string(orchestration.EventThreadImported),
			string(orchestration.EventThreadMetaUpdated),
			string(orchestration.EventThreadMessageSent),
			string(orchestration.EventThreadTurnStartRequested),
			string(orchestration.EventThreadTurnInterruptRequested),
			string(orchestration.EventThreadTurnInterruptConfirmed),
			string(orchestration.EventThreadTurnInterruptFailed),
			string(orchestration.EventThreadApprovalResponseRequested),
			string(orchestration.EventThreadSessionPrepareRequested),
			string(orchestration.EventThreadSessionStopRequested),
			string(orchestration.EventThreadSessionStopFailed),
			string(orchestration.EventThreadConfigOptionSetRequested),
			string(orchestration.EventThreadSessionStatusSet),
			string(orchestration.EventThreadItemUpserted),
			string(orchestration.EventThreadPlanUpdated),
			string(orchestration.EventThreadApprovalOpened),
			string(orchestration.EventThreadApprovalResolved),
			string(orchestration.EventThreadConfigOptionsUpdated),
			string(orchestration.EventThreadSlashCommandsUpdated),
			string(orchestration.EventThreadSkillsUpdated),
			string(orchestration.EventThreadTokenUsageUpdated),
			string(orchestration.EventThreadHistoryReplayCompleted),
		},
	},
	{
		Name:        "CommandType",
		Description: "Type discriminator of a client command sent to orchestration.dispatchCommand.",
		Values: []string{
			orchestration.CommandThreadCreate,
			orchestration.CommandThreadStart,
			orchestration.CommandThreadMetaUpdate,
			orchestration.CommandThreadTurnStart,
			orchestration.CommandThreadTurnRetry,
			orchestration.CommandThreadTurnInterrupt,
			orchestration.CommandThreadApprovalRespond,
			orchestration.CommandThreadSessionPrepare,
			orchestration.CommandThreadSessionStop,
			orchestration.CommandThreadConfigOptionSet,
		},
	},
	{
		Name:        "StreamItemKind",
		Description: "Payload discriminator of a subscription snapshot or update.",
		Values: []string{
			orchestration.StreamItemSnapshot,
			orchestration.StreamItemEvent,
			orchestration.StreamItemThreadUpserted,
		},
	},
	{
		Name:        "ActorKind",
		Description: "Origin of a thread event.",
		Values: []string{
			string(orchestration.ActorKindClient),
			string(orchestration.ActorKindServer),
			string(orchestration.ActorKindProvider),
		},
	},
	{
		Name:        "TimelineEntryKind",
		Description: "Which payload of a timeline entry's tagged union is populated.",
		Values: []string{
			string(orchestration.TimelineEntryMessage),
			string(orchestration.TimelineEntryItem),
			string(orchestration.TimelineEntryApproval),
		},
	},
	{
		Name:        "MessageRole",
		Description: "Author of a timeline message.",
		Values: []string{
			string(orchestration.MessageRoleUser),
			string(orchestration.MessageRoleAssistant),
		},
	},
	{
		Name:        "TurnState",
		Description: "Lifecycle state of a thread's latest turn.",
		Values: []string{
			string(orchestration.TurnStateRunning),
			string(orchestration.TurnStateInterrupted),
			string(orchestration.TurnStateCompleted),
			string(orchestration.TurnStateError),
		},
	},
	{
		Name:        "SessionStatus",
		Description: "Status of a thread's provider session binding.",
		Values: []string{
			string(orchestration.SessionStatusStarting),
			string(orchestration.SessionStatusRunning),
			string(orchestration.SessionStatusReady),
			string(orchestration.SessionStatusInterrupted),
			string(orchestration.SessionStatusStopped),
			string(orchestration.SessionStatusError),
		},
	},
	{
		Name:        "ApprovalStatus",
		Description: "Whether an approval request is still awaiting a decision.",
		Values: []string{
			string(orchestration.ApprovalStatusPending),
			string(orchestration.ApprovalStatusResolved),
		},
	},
	{
		Name:        "ApprovalDecision",
		Description: "Client decision on an approval request.",
		Values: []string{
			string(provider.ApprovalDecisionAccept),
			string(provider.ApprovalDecisionAcceptForSession),
			string(provider.ApprovalDecisionDecline),
			string(provider.ApprovalDecisionCancel),
		},
	},
	{
		Name:        "RequestType",
		Description: "What an approval request is asking permission for.",
		Values: []string{
			string(provider.RuntimeRequestCommandExecution),
			string(provider.RuntimeRequestFileRead),
			string(provider.RuntimeRequestFileChange),
			string(provider.RuntimeRequestDynamicToolCall),
		},
	},
	{
		Name:        "ItemKind",
		Description: "Kind of a non-message timeline item.",
		Values: []string{
			string(provider.ItemKindUserMessage),
			string(provider.ItemKindAssistantMessage),
			string(provider.ItemKindReasoning),
			string(provider.ItemKindCommandExecution),
			string(provider.ItemKindFileChange),
			string(provider.ItemKindMCPToolCall),
			string(provider.ItemKindToolCall),
			string(provider.ItemKindWarning),
			string(provider.ItemKindError),
			string(provider.ItemKindWebSearch),
			string(provider.ItemKindImageView),
			string(provider.ItemKindImageGeneration),
			string(provider.ItemKindContextCompaction),
		},
	},
	{
		Name:        "ItemStatus",
		Description: "Lifecycle status of a timeline item.",
		Values: []string{
			string(provider.ItemStatusInProgress),
			string(provider.ItemStatusCompleted),
			string(provider.ItemStatusFailed),
			string(provider.ItemStatusInterrupted),
			string(provider.ItemStatusDeclined),
		},
	},
	{
		Name:        "ToolAction",
		Description: "Action a provider explicitly stated for a tool call; absent when it stated none.",
		Values: []string{
			string(provider.ToolActionRead),
			string(provider.ToolActionSearch),
		},
	},
	{
		Name:        "FileChangeKind",
		Description: "Kind of a normalized file mutation produced by a tool.",
		Values: []string{
			string(provider.FileChangeAdd),
			string(provider.FileChangeUpdate),
			string(provider.FileChangeDelete),
			string(provider.FileChangeMove),
		},
	},
	{
		Name:        "ConfigOptionType",
		Description: "Control a session config option renders as.",
		Values: []string{
			string(provider.ConfigOptionTypeSelect),
			string(provider.ConfigOptionTypeBoolean),
		},
	},
	{
		Name:        "ConfigOptionCategory",
		Description: "Advisory grouping hint for a session config option; unknown values must be tolerated.",
		Values: []string{
			string(provider.ConfigOptionCategoryModel),
			string(provider.ConfigOptionCategoryMode),
			string(provider.ConfigOptionCategoryModelConfig),
			string(provider.ConfigOptionCategoryThoughtLevel),
			string(provider.ConfigOptionCategoryOther),
		},
	},
	{
		Name:        "PlanEntryStatus",
		Description: "Status of an execution-plan checklist entry.",
		Values: []string{
			string(provider.PlanEntryStatusPending),
			string(provider.PlanEntryStatusInProgress),
			string(provider.PlanEntryStatusCompleted),
		},
	},
	{
		Name:        "PlanEntryPriority",
		Description: "Priority of an execution-plan checklist entry.",
		Values: []string{
			string(provider.PlanEntryPriorityHigh),
			string(provider.PlanEntryPriorityMedium),
			string(provider.PlanEntryPriorityLow),
		},
	},
	{
		Name:        "InstanceStatus",
		Description: "Lifecycle of a provider instance: configured but never started this run, alive, or exited.",
		Values: []string{
			string(provider.InstanceStatusConfigured),
			string(provider.InstanceStatusInitialized),
			string(provider.InstanceStatusExited),
		},
	},
	{
		Name:        "AuthStatus",
		Description: "Provider authentication state. Unknown means the agent advertises auth methods but exposes no probe.",
		Values: []string{
			string(provider.AuthStatusUnknown),
			string(provider.AuthStatusAuthenticated),
			string(provider.AuthStatusUnauthenticated),
		},
	},
	{
		Name:        "ModelSwitchSupport",
		Description: "Whether a provider can change the active model for a thread.",
		Values: []string{
			string(provider.ModelSwitchUnsupported),
			string(provider.ModelSwitchInSession),
		},
	},
	{
		Name:        "TerminalStatus",
		Description: "Lifecycle of a terminal thread's shell run. Unknown future values must render as a neutral unavailable state.",
		Values: []string{
			string(terminal.StatusStarting),
			string(terminal.StatusRunning),
			string(terminal.StatusExited),
			string(terminal.StatusStopped),
			string(terminal.StatusError),
		},
	},
	{
		Name:        "TerminalStreamItemKind",
		Description: "Payload discriminator of a terminal.subscribe notification.",
		Values: []string{
			string(terminal.StreamItemOutput),
			string(terminal.StreamItemStatus),
		},
	},
	{
		Name:        "TerminalListStreamItemKind",
		Description: "Payload discriminator of a terminal.subscribeList snapshot or update.",
		Values: []string{
			string(TerminalListItemSnapshot),
			string(TerminalListItemUpserted),
			string(TerminalListItemRemoved),
		},
	},
	{
		Name:        "TerminalAgentActivity",
		Description: "Semantic activity of a terminal's detected coding agent. Blocked renders as “Needs input”; unknown renders neutrally, never as an error.",
		Values: []string{
			string(terminal.AgentActivityNone),
			string(terminal.AgentActivityIdle),
			string(terminal.AgentActivityWorking),
			string(terminal.AgentActivityBlocked),
			string(terminal.AgentActivityDone),
			string(terminal.AgentActivityUnknown),
		},
	},
}

// VocabularyDefinition is one closed set of wire string values.
type VocabularyDefinition struct {
	Name        string   `json:"name"`
	Description string   `json:"description,omitempty"`
	Values      []string `json:"values"`
}
