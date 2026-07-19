// Command generate-wire-schema emits the complete client-visible JSON Schema.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/invopop/jsonschema"
)

// contract is a schema catalog, not a value sent over the wire. Keeping every
// public shape reachable here makes omissions visible in code review and gives
// cross-language generators one stable input document.
type contract struct {
	EmptyParams                 wire.EmptyParams                 `json:"emptyParams"`
	Command                     wire.Command                     `json:"command"`
	CommandMessage              wire.CommandMessage              `json:"commandMessage"`
	DispatchResult              wire.DispatchResult              `json:"dispatchResult"`
	ReplayEventsParams          wire.ReplayEventsParams          `json:"replayEventsParams"`
	SubscribeThreadParams       wire.SubscribeThreadParams       `json:"subscribeThreadParams"`
	ThreadStreamItem            wire.ThreadStreamItem            `json:"threadStreamItem"`
	ThreadListStreamItem        wire.ThreadListStreamItem        `json:"threadListStreamItem"`
	ThreadDetailSnapshot        wire.ThreadDetailSnapshot        `json:"threadDetailSnapshot"`
	ThreadListSnapshot          wire.ThreadListSnapshot          `json:"threadListSnapshot"`
	ThreadListEntry             wire.ThreadListEntry             `json:"threadListEntry"`
	Event                       wire.Event                       `json:"event"`
	EventMetadata               wire.EventMetadata               `json:"eventMetadata"`
	EventPayload                wire.EventPayload                `json:"eventPayload"`
	ApprovalEvent               wire.ApprovalEvent               `json:"approvalEvent"`
	Thread                      wire.Thread                      `json:"thread"`
	Turn                        wire.Turn                        `json:"turn"`
	Message                     wire.Message                     `json:"message"`
	Approval                    wire.Approval                    `json:"approval"`
	SessionBinding              wire.SessionBinding              `json:"sessionBinding"`
	Item                        wire.Item                        `json:"item"`
	TimelineEntry               wire.TimelineEntry               `json:"timelineEntry"`
	Plan                        wire.Plan                        `json:"plan"`
	InstanceInfo                wire.InstanceInfo                `json:"instanceInfo"`
	SessionSummary              wire.SessionSummary              `json:"sessionSummary"`
	Attachment                  wire.Attachment                  `json:"attachment"`
	ModelSelection              wire.ModelSelection              `json:"modelSelection"`
	ConfigOption                wire.ConfigOption                `json:"configOption"`
	ConfigChoice                wire.ConfigChoice                `json:"configChoice"`
	SlashCommand                wire.SlashCommand                `json:"slashCommand"`
	TokenUsage                  wire.TokenUsage                  `json:"tokenUsage"`
	ApprovalOption              wire.ApprovalOption              `json:"approvalOption"`
	ProviderStartParams         wire.ProviderStartParams         `json:"providerStartParams"`
	ACPRegistryStartParams      wire.ACPRegistryStartParams      `json:"acpRegistryStartParams"`
	ProviderAuthenticateParams  wire.ProviderAuthenticateParams  `json:"providerAuthenticateParams"`
	ProviderInstanceParams      wire.ProviderInstanceParams      `json:"providerInstanceParams"`
	ProviderListSessionsParams  wire.ProviderListSessionsParams  `json:"providerListSessionsParams"`
	ProviderSessionParams       wire.ProviderSessionParams       `json:"providerSessionParams"`
	ProviderImportSessionParams wire.ProviderImportSessionParams `json:"providerImportSessionParams"`
	ProviderImportSessionResult wire.ProviderImportSessionResult `json:"providerImportSessionResult"`
	ACPRegistryAgent            wire.ACPRegistryAgent            `json:"acpRegistryAgent"`
}

func main() {
	out := flag.String("out", "api/generated/client-api.schema.json", "schema output path")
	methodsOut := flag.String("methods-out", "api/generated/rpc-methods.json", "method registry output path")
	flag.Parse()

	r := &jsonschema.Reflector{
		Anonymous:      true,
		DoNotReference: false,
		FieldNameTag:   "json",
	}
	schema := r.Reflect(contract{})
	schema.ID = "https://maid.local/schema/client-api-v1.json"
	schema.Title = "maiD Client API v1"
	schema.Description = "Client-visible JSON-RPC parameters, results, notifications, and shared models."
	// Quicktype otherwise derives some model names from their use sites (for
	// example, CommandMessageClass). Explicit titles preserve the Go wire names
	// in generated clients without language-specific aliases.
	for name, definition := range schema.Definitions {
		definition.Title = name
	}

	data, err := json.MarshalIndent(schema, "", "  ")
	if err != nil {
		fatal(err)
	}
	data = append(data, '\n')
	if err := os.MkdirAll(filepath.Dir(*out), 0o755); err != nil {
		fatal(err)
	}
	if err := os.WriteFile(*out, data, 0o644); err != nil {
		fatal(err)
	}

	methods := struct {
		Methods       []wire.MethodDefinition       `json:"methods"`
		Notifications []wire.NotificationDefinition `json:"notifications"`
	}{wire.Methods, wire.Notifications}
	methodData, err := json.MarshalIndent(methods, "", "  ")
	if err != nil {
		fatal(err)
	}
	methodData = append(methodData, '\n')
	if err := os.MkdirAll(filepath.Dir(*methodsOut), 0o755); err != nil {
		fatal(err)
	}
	if err := os.WriteFile(*methodsOut, methodData, 0o644); err != nil {
		fatal(err)
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
