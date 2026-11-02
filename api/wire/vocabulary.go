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
		Name:        "CommandErrorCode",
		Description: "Why thread.command refused a command: the data.code of its JSON-RPC error.",
		Values: []string{
			string(orchestration.CodeOutOfScope),
			string(orchestration.CodeCeilingExceeded),
			string(orchestration.CodeDepthExceeded),
			string(orchestration.CodeAgentUnavailable),
			string(orchestration.CodeNotFound),
			string(orchestration.CodeNotRunning),
			string(orchestration.CodePermissionRequest),
			string(orchestration.CodeInvalid),
		},
	},
	{
		Name:        "ACPAgentSource",
		Description: "Where an ACP agent's definition comes from.",
		Values:      []string{string(ACPAgentSourceRegistry), string(ACPAgentSourceCustom)},
	},
	{
		Name:        "ACPAgentState",
		Description: "What the daemon is doing with an ACP agent's files. Failed says the last install or update failed; an installed version keeps working.",
		Values: []string{
			string(ACPAgentNotInstalled),
			string(ACPAgentInstalling),
			string(ACPAgentInstalled),
			string(ACPAgentUpdating),
			string(ACPAgentFailed),
		},
	},
	{
		Name:        "ACPAgentBlocker",
		Description: "Why an ACP agent can't be installed on the daemon's machine.",
		Values:      []string{string(ACPAgentNeedsPlatform), string(ACPAgentNeedsNode), string(ACPAgentNeedsUV)},
	},
	{
		Name:        "ThreadStatus",
		Description: "What a thread is doing, derived from its turns, requests and queue.",
		Values: []string{
			string(orchestration.StatusRunning),
			string(orchestration.StatusWaiting),
			string(orchestration.StatusHeld),
			string(orchestration.StatusIdle),
		},
	},
	{
		Name:        "OriginKind",
		Description: "How a thread began: a person's chat, a spawned child, or a provider's own subagent.",
		Values: []string{
			string(orchestration.OriginUser),
			string(orchestration.OriginSpawn),
			string(orchestration.OriginNative),
		},
	},
	{
		Name:        "Hold",
		Description: "Why a thread's queue waits, and so who may release it; absent when nothing holds it.",
		Values: []string{
			string(orchestration.HoldStoppedPerson),
			string(orchestration.HoldStoppedAgent),
			string(orchestration.HoldFailed),
			string(orchestration.HoldHops),
		},
	},
	{
		Name:        "StartedBy",
		Description: "What started a turn.",
		Values: []string{
			string(orchestration.StartedByDelivery),
			string(orchestration.StartedByProvider),
			string(orchestration.StartedByFound),
		},
	},
	{
		Name:        "DeliveryKind",
		Description: "Who a delivery is from: a person's prompt, an agent's message, a reply, a daemon notice.",
		Values: []string{
			string(orchestration.KindPrompt),
			string(orchestration.KindMessage),
			string(orchestration.KindReply),
			string(orchestration.KindNotice),
		},
	},
	{
		Name:        "DeliveryMode",
		Description: "How a delivery goes: as the next turn, or into the running one.",
		Values: []string{
			string(orchestration.ModeQueue),
			string(orchestration.ModeSteer),
		},
	},
	{
		Name:        "DeliveryState",
		Description: "Where a delivery is on its way to the agent.",
		Values: []string{
			string(orchestration.DeliveryQueued),
			string(orchestration.DeliverySending),
			string(orchestration.DeliveryDelivered),
			string(orchestration.DeliveryRefused),
			string(orchestration.DeliveryCancelled),
		},
	},
	{
		Name:        "ActorKind",
		Description: "Who sent a delivery or issued a command.",
		Values: []string{
			string(orchestration.ActorDevice),
			string(orchestration.ActorAgent),
			string(orchestration.ActorDaemon),
		},
	},
	{
		Name:        "WakeMode",
		Description: "When a spawned thread's parent hears from it.",
		Values: []string{
			string(orchestration.WakeSettled),
			string(orchestration.WakeNeedsInput),
		},
	},
	{
		Name:        "ThreadEventKind",
		Description: "Which change a thread.event notification carries.",
		Values: []string{
			string(orchestration.EventEntry),
			string(orchestration.EventText),
			string(orchestration.EventTurn),
			string(orchestration.EventDelivery),
			string(orchestration.EventRequest),
			string(orchestration.EventResolved),
			string(orchestration.EventParticipant),
			string(orchestration.EventThread),
			string(orchestration.EventChild),
			string(orchestration.EventPlan),
			string(orchestration.EventRefresh),
			string(orchestration.EventRemoved),
		},
	},
	{
		Name:        "ThreadListKind",
		Description: "Whether a thread.list item is the snapshot, an upsert or a removal.",
		Values: []string{
			string(orchestration.ListSnapshot),
			string(orchestration.ListUpsert),
			string(orchestration.ListRemove),
		},
	},
	{
		Name:        "TurnState",
		Description: "Lifecycle state of a turn.",
		Values: []string{
			string(provider.TurnRunning),
			string(provider.TurnCompleted),
			string(provider.TurnFailed),
			string(provider.TurnInterrupted),
		},
	},
	{
		Name:        "StreamKind",
		Description: "What streamed text adds to.",
		Values: []string{
			string(provider.StreamAssistant),
			string(provider.StreamReasoning),
		},
	},
	{
		Name:        "EnvelopeKind",
		Description: "What a block maiD wrapped around text it sent an agent carries.",
		Values: []string{
			string(provider.EnvelopeHandoff),
			string(provider.EnvelopeMessage),
			string(provider.EnvelopeReply),
			string(provider.EnvelopeNotice),
			string(provider.EnvelopeInstructions),
		},
	},
	{
		Name:        "HistoryQuality",
		Description: "How well a provider rebuilds a session run outside maiD from its own record.",
		Values: []string{
			string(provider.HistoryNone),
			string(provider.HistoryLossy),
			string(provider.HistoryExact),
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
		Name:        "AuthKind",
		Description: "How a sign-in method or challenge proceeds.",
		Values: []string{
			string(provider.AuthKindBrowser),
			string(provider.AuthKindDeviceCode),
			string(provider.AuthKindSecret),
			string(provider.AuthKindTerminal),
		},
	},
	{
		Name:        "AttachmentKind",
		Description: "What a message or tool attachment carries.",
		Values: []string{
			string(provider.AttachmentImage),
			string(provider.AttachmentAudio),
			string(provider.AttachmentResource),
			string(provider.AttachmentResourceLink),
		},
	},
	{
		Name:        "StopReason",
		Description: "Why a completed turn ended early; absent when it finished normally.",
		Values: []string{
			string(provider.StopReasonMaxTokens),
			string(provider.StopReasonMaxTurnRequests),
			string(provider.StopReasonRefusal),
		},
	},
	{
		Name:        "OutputFormat",
		Description: "How to render tool output; absent means plain text.",
		Values:      []string{string(provider.OutputFormatMarkdown)},
	},
	{
		Name:        "QuestionKind",
		Description: "Input a user-input question takes.",
		Values: []string{
			string(provider.QuestionKindText),
			string(provider.QuestionKindNumber),
			string(provider.QuestionKindInteger),
			string(provider.QuestionKindChoice),
		},
	},
	{
		Name:        "AccessLevel",
		Description: "How much a session may do without asking, from read_only to full; absent when its mode isn't mapped.",
		Values: []string{
			string(provider.AccessReadOnly),
			string(provider.AccessAsk),
			string(provider.AccessEdit),
			string(provider.AccessFull),
		},
	},
	{
		Name:        "ItemKind",
		Description: "Kind of an entry of a session's conversation.",
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
			string(provider.ItemKindEnvelope),
			string(provider.ItemKindRequest),
		},
	},
	{
		Name:        "ItemStatus",
		Description: "Lifecycle status of an entry.",
		Values: []string{
			string(provider.ItemStatusInProgress),
			string(provider.ItemStatusCompleted),
			string(provider.ItemStatusFailed),
			string(provider.ItemStatusInterrupted),
			string(provider.ItemStatusDeclined),
		},
	},
	{
		Name:        "GoalStatus",
		Description: "Status of the goal a provider pursues over its turns.",
		Values: []string{
			string(provider.GoalActive),
			string(provider.GoalPaused),
			string(provider.GoalBlocked),
			string(provider.GoalUsageLimited),
			string(provider.GoalBudgetLimited),
			string(provider.GoalComplete),
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
		Name:        "TerminalListStreamItemKind",
		Description: "Payload discriminator of a terminal.subscribeList snapshot or update.",
		Values: []string{
			string(TerminalListItemSnapshot),
			string(TerminalListItemUpserted),
			string(TerminalListItemRemoved),
		},
	},
	{
		Name:        "TerminalProgramState",
		Description: "What a terminal's program reported doing (OSC 7501). Blocked renders as needing the user; unknown future values render neutrally.",
		Values: []string{
			string(terminal.ProgramIdle),
			string(terminal.ProgramWorking),
			string(terminal.ProgramDone),
			string(terminal.ProgramBlocked),
			string(terminal.ProgramError),
		},
	},
	{
		Name:        "TerminalProgramNeed",
		Description: "What a blocked terminal program needs from the user. Unknown future values render like no need given.",
		Values: []string{
			string(terminal.ProgramNeedsPermission),
			string(terminal.ProgramNeedsAnswer),
			string(terminal.ProgramNeedsAuth),
		},
	},
	{
		Name:        "TerminalColorScheme",
		Description: "Whether a terminal view's theme is light or dark.",
		Values: []string{
			string(terminal.ColorSchemeLight),
			string(terminal.ColorSchemeDark),
		},
	},
}

// VocabularyDefinition is one closed set of wire string values.
type VocabularyDefinition struct {
	Name        string   `json:"name"`
	Description string   `json:"description,omitempty"`
	Values      []string `json:"values"`
}
