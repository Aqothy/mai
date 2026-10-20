// Package wire defines the versioned JSON contract shared by the daemon and
// generated clients. Domain packages may implement these shapes, but every
// JSON-RPC parameter/result and notification exposed to clients must be listed
// here so `go generate ./api/wire` detects contract changes.
package wire

import (
	"time"

	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
)

const (
	MethodOrchestrationDispatchCommand     = "orchestration.dispatchCommand"
	MethodOrchestrationSubscribeThreadList = "orchestration.subscribeThreadList"
	MethodOrchestrationSubscribeThread     = "orchestration.subscribeThread"
	MethodOrchestrationUnsubscribeThread   = "orchestration.unsubscribeThread"
	MethodOrchestrationGetItemDetail       = "orchestration.getItemDetail"
	MethodOrchestrationGetAttachment       = "orchestration.getAttachment"
	MethodOrchestrationUploadAttachment    = "orchestration.uploadAttachment"

	MethodProviderStart              = "provider.start"
	MethodProviderList               = "provider.list"
	MethodACPRegistryList            = "acp.registry.list"
	MethodACPRegistryInstalled       = "acp.registry.installed"
	MethodACPRegistryInstall         = "acp.registry.install"
	MethodACPRegistryAddCustom       = "acp.registry.addCustom"
	MethodACPRegistryStart           = "acp.registry.start"
	MethodProviderAuthenticate       = "provider.authenticate"
	MethodProviderLogout             = "provider.logout"
	MethodProviderListSessions       = "provider.listSessions"
	MethodProviderImportSession      = "provider.importSession"
	MethodProviderDeleteSession      = "provider.deleteSession"
	MethodProviderCloseSession       = "provider.closeSession"
	MethodProviderForkThread         = "provider.forkThread"
	MethodProviderOptionsGet         = "provider.options.get"
	MethodProviderOptionsSet         = "provider.options.set"
	MethodProviderOptionsUpdated     = "provider.options.updated"
	MethodProviderOptionsInvalidated = "provider.options.invalidated"
	MethodProviderQuestionAsked      = "provider.question.asked"
	MethodProviderQuestionAnswer     = "provider.question.answer"
	MethodProviderCompleteCommand    = "provider.completeCommand"
)

// EmptyParams is the params object sent to methods that take no arguments.
type EmptyParams struct{}

// Client-visible orchestration types. Aliases deliberately keep the current
// wire format identical while making the complete contract discoverable from
// this package.
type Command = orchestration.Command
type CommandMessage = orchestration.CommandMessage
type DispatchResult = orchestration.DispatchResult
type SubscribeThreadParams = orchestration.SubscribeThreadInput
type GetItemDetailParams = orchestration.GetItemDetailInput
type GetAttachmentParams = orchestration.GetAttachmentInput
type ThreadStreamItem = orchestration.ThreadStreamItem
type ThreadListStreamItem = orchestration.ThreadListStreamItem
type ThreadDetailSnapshot = orchestration.ThreadDetailSnapshot
type ThreadListSnapshot = orchestration.ThreadListSnapshot
type ThreadListEntry = orchestration.ThreadListEntry
type Event = orchestration.Event
type EventMetadata = orchestration.EventMetadata
type EventPayload = orchestration.EventPayload
type ApprovalEvent = orchestration.ApprovalEvent
type Thread = orchestration.Thread
type Turn = orchestration.Turn
type Message = orchestration.Message
type Approval = orchestration.Approval
type SessionBinding = orchestration.SessionBinding
type Item = orchestration.Item
type ToolCallSummary = orchestration.ToolCallSummary
type FileChangeSummary = orchestration.FileChangeSummary
type ToolAttachmentSummary = orchestration.ToolAttachmentSummary
type TimelineEntry = orchestration.TimelineEntry
type Plan = orchestration.Plan

// Client-visible provider types.
type InstanceInfo = provider.InstanceInfo
type AuthenticationResult = provider.AuthenticationResult
type SessionSummary = provider.SessionSummary
type Attachment = provider.Attachment
type PromptAnnotation = provider.PromptAnnotation
type ModelSelection = provider.ModelSelection
type ConfigOption = provider.ConfigOption
type ConfigChoice = provider.ConfigChoice
type ConfigOptionSelection = provider.ConfigOptionSelection
type SlashCommand = provider.SlashCommand
type ProviderCompleteCommandParams = provider.CompleteCommandInput
type CommandCompletion = provider.CommandCompletion
type Skill = provider.Skill
type TokenUsage = provider.TokenUsage
type Goal = provider.Goal
type RequestAction = provider.RequestAction

// ProviderStartParams starts a configured provider. Config is adapter-owned
// JSON and is intentionally unconstrained by the shared contract.
type ProviderStartParams struct {
	provider.InstanceSpec
	Restart bool `json:"restart,omitempty"`
}

// AttachmentUploadParams carries one attachment's data ahead of the
// thread.start or thread.turn.start command that sends it. The command lists
// the attachment by ID without data, so no single message grows with the
// number of attachments.
type AttachmentUploadParams struct {
	ID   string `json:"id"`
	Data string `json:"data"`
}

type ACPRegistryStartParams struct {
	RegistryID string `json:"registryId"`
	Restart    bool   `json:"restart,omitempty"`
}

type ACPRegistryInstallParams struct {
	RegistryID string `json:"registryId"`
}

// ACPCustomAgentAddParams contains only user-facing launch configuration.
// Name determines the stable definition identity; the daemon owns persistence.
type ACPCustomAgentAddParams struct {
	Name    string            `json:"name"`
	Command string            `json:"command"`
	Args    []string          `json:"args,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
}

// ProviderQuestion is a question an agent asks during provider.authenticate,
// outside any thread. It goes to the client whose sign-in is running, which
// answers it with provider.question.answer before the sign-in can finish.
type ProviderQuestion struct {
	InstanceID provider.InstanceID `json:"instanceId"`
	RequestID  string              `json:"requestId"`
	Request    provider.Request    `json:"request"`
}

// ProviderQuestionAnswerParams answers a ProviderQuestion with one of its
// request's actions, and Answers its questions when the action submits them.
type ProviderQuestionAnswerParams struct {
	RequestID string              `json:"requestId"`
	ActionID  string              `json:"actionId"`
	Answers   map[string][]string `json:"answers,omitempty"`
}

type ProviderAuthenticateParams struct {
	InstanceID provider.InstanceID `json:"instanceId"`
	MethodID   string              `json:"methodId"`
	Secret     string              `json:"secret,omitempty"`
}

// ProviderForkThreadParams forks a thread's turns through ThroughTurnID, or
// up to BeforeTurnID, or, with neither, all of them; only the turns the
// provider ran to the end are kept.
type ProviderForkThreadParams struct {
	SourceThreadID orchestration.ThreadID `json:"sourceThreadId"`
	ThroughTurnID  orchestration.TurnID   `json:"throughTurnId,omitempty"`
	BeforeTurnID   orchestration.TurnID   `json:"beforeTurnId,omitempty"`
	// ProviderInstanceID continues the thread in another agent; empty keeps
	// the thread's own.
	ProviderInstanceID provider.InstanceID `json:"providerInstanceId,omitempty"`
}

// ProviderForkThreadResult is the fork: ThreadID holds the provider's native
// fork, or, when the provider can't make it natively, Draft is a new chat
// whose thread.start hands the conversation to a new session.
type ProviderForkThreadResult struct {
	ThreadID orchestration.ThreadID `json:"threadId,omitempty"`
	Draft    *ForkDraft             `json:"draft,omitempty"`
}

// ForkDraft is a new chat with the forked thread's provider, workspace and
// settings.
type ForkDraft struct {
	SourceTitle           string                           `json:"sourceTitle"`
	ProviderInstanceID    provider.InstanceID              `json:"providerInstanceId"`
	Cwd                   string                           `json:"cwd"`
	AdditionalDirectories []string                         `json:"additionalDirectories,omitempty"`
	ConfigSelections      []provider.ConfigOptionSelection `json:"configSelections,omitempty"`
	// ForkContext goes in the draft's thread.start; it is empty when the fork
	// keeps no turns.
	ForkContext string `json:"forkContext,omitempty"`
}

type ProviderInstanceParams struct {
	InstanceID provider.InstanceID `json:"instanceId"`
}

type ProviderListSessionsParams struct {
	InstanceID provider.InstanceID `json:"instanceId"`
	Cwd        string              `json:"cwd,omitempty"`
}

type ProviderSessionParams struct {
	InstanceID provider.InstanceID `json:"instanceId"`
	SessionID  string              `json:"sessionId"`
}

type ProviderImportSessionParams struct {
	InstanceID provider.InstanceID `json:"instanceId"`
	Session    SessionSummary      `json:"session"`
}

type ProviderImportSessionResult struct {
	ThreadID orchestration.ThreadID `json:"threadId"`
	Imported bool                   `json:"imported"`
}

type ProviderOptionsGetParams struct {
	ProviderInstanceID provider.InstanceID `json:"providerInstanceId"`
	Cwd                string              `json:"cwd"`
}

type ProviderOptionsSetParams struct {
	OptionsSessionID string `json:"optionsSessionId"`
	OptionID         string `json:"optionId"`
	Value            any    `json:"value"`
}

type ProviderOptionsResult struct {
	OptionsSessionID string                  `json:"optionsSessionId"`
	ConfigOptions    []provider.ConfigOption `json:"configOptions"`
	Skills           []provider.Skill        `json:"skills,omitempty"`
}

type ProviderOptionsInvalidated struct {
	OptionsSessionID string `json:"optionsSessionId"`
}

// ACPRegistryAgent is a safe, installable entry returned by the public ACP
// registry. Environment variables remain server-only and are not represented.
type ACPRegistryAgent struct {
	ID          string              `json:"id"`
	InstanceID  provider.InstanceID `json:"instanceId"`
	Name        string              `json:"name"`
	Version     string              `json:"version,omitempty"`
	Description string              `json:"description,omitempty"`
	Icon        string              `json:"icon,omitempty"`
	Package     string              `json:"package"`
	Args        []string            `json:"args,omitempty"`
}

// ACPRegistryInstalledAgent describes a registry or custom ACP agent persisted
// by the daemon. npm acquires registry packages lazily when they start, bounded
// by Version. Custom launch configuration and all environment variables remain
// server-only and are not represented.
type ACPRegistryInstalledAgent struct {
	ID          string              `json:"id"`
	InstanceID  provider.InstanceID `json:"instanceId"`
	Name        string              `json:"name"`
	Source      string              `json:"source"`
	Version     string              `json:"version"`
	Description string              `json:"description,omitempty"`
	Icon        string              `json:"icon,omitempty"`
	Package     string              `json:"package"`
	Args        []string            `json:"args,omitempty"`
	InstalledAt time.Time           `json:"installedAt"`
}
