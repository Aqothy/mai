// Package wire defines the versioned JSON contract shared by the daemon and
// generated clients. Domain packages may implement these shapes, but every
// JSON-RPC parameter/result and notification exposed to clients must be listed
// here so `go generate ./api/wire` detects contract changes.
package wire

import (
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
)

const (
	MethodOrchestrationDispatchCommand     = "orchestration.dispatchCommand"
	MethodOrchestrationReplayEvents        = "orchestration.replayEvents"
	MethodOrchestrationSubscribeThreadList = "orchestration.subscribeThreadList"
	MethodOrchestrationSubscribeThread     = "orchestration.subscribeThread"
	MethodOrchestrationUnsubscribeThread   = "orchestration.unsubscribeThread"

	MethodProviderStart         = "provider.start"
	MethodProviderList          = "provider.list"
	MethodACPRegistryList       = "acp.registry.list"
	MethodACPRegistryStart      = "acp.registry.start"
	MethodProviderAuthenticate  = "provider.authenticate"
	MethodProviderLogout        = "provider.logout"
	MethodProviderListSessions  = "provider.listSessions"
	MethodProviderImportSession = "provider.importSession"
	MethodProviderDeleteSession = "provider.deleteSession"
	MethodProviderCloseSession  = "provider.closeSession"
)

// EmptyParams is the params object sent to methods that take no arguments.
type EmptyParams struct{}

// Client-visible orchestration types. Aliases deliberately keep the current
// wire format identical while making the complete contract discoverable from
// this package.
type Command = orchestration.Command
type CommandMessage = orchestration.CommandMessage
type DispatchResult = orchestration.DispatchResult
type ReplayEventsParams = orchestration.ReplayEventsInput
type SubscribeThreadParams = orchestration.SubscribeThreadInput
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
type TimelineEntry = orchestration.TimelineEntry
type Plan = orchestration.Plan

// Client-visible provider types.
type InstanceInfo = provider.InstanceInfo
type SessionSummary = provider.SessionSummary
type Attachment = provider.Attachment
type ModelSelection = provider.ModelSelection
type ConfigOption = provider.ConfigOption
type ConfigChoice = provider.ConfigChoice
type SlashCommand = provider.SlashCommand
type TokenUsage = provider.TokenUsage
type ApprovalOption = provider.ApprovalOption

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

type ProviderAuthenticateParams struct {
	InstanceID provider.InstanceID `json:"instanceId"`
	MethodID   string              `json:"methodId"`
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
