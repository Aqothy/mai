// Package wire defines the versioned JSON contract shared by the daemon and
// generated clients. Domain packages may implement these shapes, but every
// JSON-RPC parameter/result and notification exposed to clients must be listed
// here so `go generate ./api/wire` detects contract changes.
package wire

import (
	"fmt"
	"time"

	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
)

const (
	MethodThreadCommand       = "thread.command"
	MethodThreadSubscribeList = "thread.subscribeList"
	MethodThreadList          = "thread.list"
	MethodThreadSubscribe     = "thread.subscribe"
	MethodThreadEvent         = "thread.event"
	MethodThreadUnsubscribe   = "thread.unsubscribe"
	MethodThreadSync          = "thread.sync"
	MethodThreadTurns         = "thread.turns"
	MethodThreadEntry         = "thread.entry"
	MethodThreadForkPreview   = "thread.forkPreview"
	MethodAttachmentUpload    = "attachment.upload"
	MethodAttachmentGet       = "attachment.get"

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
	MethodProviderDeleteSession      = "provider.deleteSession"
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

// Client-visible orchestration types: the thread list, a thread's snapshot
// and events, and the commands that change them.
type (
	ThreadSummary      = orchestration.ThreadSummary
	OriginSummary      = orchestration.OriginSummary
	ParticipantSummary = orchestration.ParticipantSummary
	ParticipantView    = orchestration.ParticipantView
	Attention          = orchestration.Attention
	ForkPreview        = orchestration.ForkPreview
	ThreadSnapshot     = orchestration.ThreadSnapshot
	TurnView           = orchestration.TurnView
	EntryView          = orchestration.EntryView
	DeliveryView       = orchestration.DeliveryView
	ActorView          = orchestration.ActorView
	RequestView        = orchestration.RequestView
	ThreadEvent        = orchestration.ThreadEvent
	TextAppend         = orchestration.TextAppend
	RequestResolution  = orchestration.RequestResolution
	ThreadListItem     = orchestration.ThreadListItem
	ToolCallSummary    = orchestration.ToolCallSummary
	FileChangeSummary  = orchestration.FileChangeSummary
	ToolAttachment     = orchestration.ToolAttachmentSummary
	ForkPoint          = orchestration.ForkPoint
	TreePolicy         = orchestration.TreePolicy
	MessageBody        = orchestration.MessageBody
	NewParticipant     = orchestration.NewParticipant
	CommandResult      = orchestration.CommandResult
	CreateThread       = orchestration.CreateThread
	UpdateThread       = orchestration.UpdateThread
	DeleteThread       = orchestration.DeleteThread
	ForkThread         = orchestration.ForkThread
	Spawn              = orchestration.Spawn
	AddParticipant     = orchestration.AddParticipant
	UpdateParticipant  = orchestration.UpdateParticipant
	Deliver            = orchestration.Deliver
	CancelDelivery     = orchestration.CancelDelivery
	MoveDelivery       = orchestration.MoveDelivery
	SteerDelivery      = orchestration.SteerDelivery
	RetryDelivery      = orchestration.RetryDelivery
	Interrupt          = orchestration.Interrupt
	Stop               = orchestration.Stop
	Continue           = orchestration.Continue
	Respond            = orchestration.Respond
	StopItem           = orchestration.StopItem
)

// Client-visible provider types.
type (
	InstanceInfo          = provider.InstanceInfo
	AuthenticationResult  = provider.AuthenticationResult
	SessionSummary        = provider.SessionSummary
	Attachment            = provider.Attachment
	PromptAnnotation      = provider.PromptAnnotation
	ConfigOption          = provider.ConfigOption
	ConfigChoice          = provider.ConfigChoice
	ConfigOptionSelection = provider.ConfigOptionSelection
	SlashCommand          = provider.SlashCommand
	CommandCompletion     = provider.CommandCompletion
	Skill                 = provider.Skill
	TokenUsage            = provider.TokenUsage
	Goal                  = provider.Goal
	RequestAction         = provider.RequestAction
	Entry                 = provider.Entry
	Envelope              = provider.Envelope
	RequestRecord         = provider.RequestRecord
	Workspace             = provider.Workspace
	PlanEntry             = provider.PlanEntry
)

// CommandParams is one command: exactly one of its fields, and a key that
// makes it idempotent (a client's command ID, retried after a dropped
// connection).
type CommandParams struct {
	Key               string             `json:"key,omitempty"`
	CreateThread      *CreateThread      `json:"createThread,omitempty"`
	UpdateThread      *UpdateThread      `json:"updateThread,omitempty"`
	DeleteThread      *DeleteThread      `json:"deleteThread,omitempty"`
	ForkThread        *ForkThread        `json:"forkThread,omitempty"`
	Spawn             *Spawn             `json:"spawn,omitempty"`
	AddParticipant    *AddParticipant    `json:"addParticipant,omitempty"`
	UpdateParticipant *UpdateParticipant `json:"updateParticipant,omitempty"`
	Deliver           *Deliver           `json:"deliver,omitempty"`
	CancelDelivery    *CancelDelivery    `json:"cancelDelivery,omitempty"`
	MoveDelivery      *MoveDelivery      `json:"moveDelivery,omitempty"`
	SteerDelivery     *SteerDelivery     `json:"steerDelivery,omitempty"`
	RetryDelivery     *RetryDelivery     `json:"retryDelivery,omitempty"`
	Interrupt         *Interrupt         `json:"interrupt,omitempty"`
	Stop              *Stop              `json:"stop,omitempty"`
	Continue          *Continue          `json:"continue,omitempty"`
	Respond           *Respond           `json:"respond,omitempty"`
	StopItem          *StopItem          `json:"stopItem,omitempty"`
}

// Body is the one command set, validated at the boundary.
func (p CommandParams) Body() (orchestration.CommandBody, error) {
	var bodies []orchestration.CommandBody
	add := func(set bool, body func() orchestration.CommandBody) {
		if set {
			bodies = append(bodies, body())
		}
	}
	add(p.CreateThread != nil, func() orchestration.CommandBody { return *p.CreateThread })
	add(p.UpdateThread != nil, func() orchestration.CommandBody { return *p.UpdateThread })
	add(p.DeleteThread != nil, func() orchestration.CommandBody { return *p.DeleteThread })
	add(p.ForkThread != nil, func() orchestration.CommandBody { return *p.ForkThread })
	add(p.Spawn != nil, func() orchestration.CommandBody { return *p.Spawn })
	add(p.AddParticipant != nil, func() orchestration.CommandBody { return *p.AddParticipant })
	add(p.UpdateParticipant != nil, func() orchestration.CommandBody { return *p.UpdateParticipant })
	add(p.Deliver != nil, func() orchestration.CommandBody { return *p.Deliver })
	add(p.CancelDelivery != nil, func() orchestration.CommandBody { return *p.CancelDelivery })
	add(p.MoveDelivery != nil, func() orchestration.CommandBody { return *p.MoveDelivery })
	add(p.SteerDelivery != nil, func() orchestration.CommandBody { return *p.SteerDelivery })
	add(p.RetryDelivery != nil, func() orchestration.CommandBody { return *p.RetryDelivery })
	add(p.Interrupt != nil, func() orchestration.CommandBody { return *p.Interrupt })
	add(p.Stop != nil, func() orchestration.CommandBody { return *p.Stop })
	add(p.Continue != nil, func() orchestration.CommandBody { return *p.Continue })
	add(p.Respond != nil, func() orchestration.CommandBody { return *p.Respond })
	add(p.StopItem != nil, func() orchestration.CommandBody { return *p.StopItem })
	if len(bodies) != 1 {
		return nil, fmt.Errorf("a command sets exactly one of its fields, not %d", len(bodies))
	}
	return bodies[0], nil
}

// ThreadParams names a thread.
type ThreadParams struct {
	Thread orchestration.ThreadID `json:"thread"`
}

// ThreadTurnsParams pages a thread's turns older than Before.
type ThreadTurnsParams struct {
	Thread orchestration.ThreadID `json:"thread"`
	Before orchestration.TurnID   `json:"before,omitempty"`
	Limit  int                    `json:"limit,omitempty"`
}

type ThreadTurnsResult struct {
	Turns []TurnView `json:"turns"`
	// Older continues the paging; empty at the thread's first turn.
	Older orchestration.TurnID `json:"older,omitempty"`
}

// ThreadForkPreviewParams asks how a fork of a thread through a turn would
// start: with the chat's own agent, or Agent instead.
type ThreadForkPreviewParams struct {
	Thread  orchestration.ThreadID `json:"thread"`
	Through orchestration.TurnID   `json:"through,omitempty"`
	Agent   provider.InstanceID    `json:"agent,omitempty"`
}

// ThreadEntryParams names one entry of a thread, read whole.
type ThreadEntryParams struct {
	Thread orchestration.ThreadID `json:"thread"`
	Ref    string                 `json:"ref"`
}

// AttachmentUploadParams carries one attachment's data ahead of the command
// that sends it; the command names it by the ID the upload returns.
type AttachmentUploadParams struct {
	Data string `json:"data"`
}

type AttachmentUploadResult struct {
	ID string `json:"id"`
}

type AttachmentParams struct {
	ID string `json:"id"`
}

// ProviderCompleteCommandParams asks a thread's agent (Participant, else its
// address) for what may follow a slash command.
type ProviderCompleteCommandParams struct {
	Thread      orchestration.ThreadID      `json:"thread"`
	Participant orchestration.ParticipantID `json:"participant,omitempty"`
	Command     string                      `json:"command"`
	Input       string                      `json:"input"`
}

// ProviderStartParams starts a configured provider. Config is adapter-owned
// JSON and is intentionally unconstrained by the shared contract.
type ProviderStartParams struct {
	provider.InstanceSpec
	Restart bool `json:"restart,omitempty"`
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
