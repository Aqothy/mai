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
	EmptyParams                      wire.EmptyParams                      `json:"emptyParams"`
	CommandParams                    wire.CommandParams                    `json:"commandParams"`
	CommandResult                    wire.CommandResult                    `json:"commandResult"`
	ThreadParams                     wire.ThreadParams                     `json:"threadParams"`
	ThreadTurnsParams                wire.ThreadTurnsParams                `json:"threadTurnsParams"`
	ThreadTurnsResult                wire.ThreadTurnsResult                `json:"threadTurnsResult"`
	ThreadEntryParams                wire.ThreadEntryParams                `json:"threadEntryParams"`
	ThreadForkPreviewParams          wire.ThreadForkPreviewParams          `json:"threadForkPreviewParams"`
	ForkPreview                      wire.ForkPreview                      `json:"forkPreview"`
	AttachmentUploadParams           wire.AttachmentUploadParams           `json:"attachmentUploadParams"`
	AttachmentUploadResult           wire.AttachmentUploadResult           `json:"attachmentUploadResult"`
	AttachmentParams                 wire.AttachmentParams                 `json:"attachmentParams"`
	ThreadSummary                    wire.ThreadSummary                    `json:"threadSummary"`
	OriginSummary                    wire.OriginSummary                    `json:"originSummary"`
	ParticipantSummary               wire.ParticipantSummary               `json:"participantSummary"`
	ParticipantView                  wire.ParticipantView                  `json:"participantView"`
	Attention                        wire.Attention                        `json:"attention"`
	ThreadSnapshot                   wire.ThreadSnapshot                   `json:"threadSnapshot"`
	TurnView                         wire.TurnView                         `json:"turnView"`
	EntryView                        wire.EntryView                        `json:"entryView"`
	DeliveryView                     wire.DeliveryView                     `json:"deliveryView"`
	ActorView                        wire.ActorView                        `json:"actorView"`
	RequestView                      wire.RequestView                      `json:"requestView"`
	ThreadEvent                      wire.ThreadEvent                      `json:"threadEvent"`
	TextAppend                       wire.TextAppend                       `json:"textAppend"`
	RequestResolution                wire.RequestResolution                `json:"requestResolution"`
	ThreadListItem                   wire.ThreadListItem                   `json:"threadListItem"`
	Project                          wire.Project                          `json:"project"`
	ProjectList                      wire.ProjectList                      `json:"projectList"`
	ProjectParams                    wire.ProjectParams                    `json:"projectParams"`
	ToolCallSummary                  wire.ToolCallSummary                  `json:"toolCallSummary"`
	FileChangeSummary                wire.FileChangeSummary                `json:"fileChangeSummary"`
	ToolAttachment                   wire.ToolAttachment                   `json:"toolAttachment"`
	ForkPoint                        wire.ForkPoint                        `json:"forkPoint"`
	TreePolicy                       wire.TreePolicy                       `json:"treePolicy"`
	MessageBody                      wire.MessageBody                      `json:"messageBody"`
	NewParticipant                   wire.NewParticipant                   `json:"newParticipant"`
	CreateThread                     wire.CreateThread                     `json:"createThread"`
	UpdateThread                     wire.UpdateThread                     `json:"updateThread"`
	DeleteThread                     wire.DeleteThread                     `json:"deleteThread"`
	ForkThread                       wire.ForkThread                       `json:"forkThread"`
	Spawn                            wire.Spawn                            `json:"spawn"`
	AddParticipant                   wire.AddParticipant                   `json:"addParticipant"`
	UpdateParticipant                wire.UpdateParticipant                `json:"updateParticipant"`
	Deliver                          wire.Deliver                          `json:"deliver"`
	CancelDelivery                   wire.CancelDelivery                   `json:"cancelDelivery"`
	MoveDelivery                     wire.MoveDelivery                     `json:"moveDelivery"`
	SteerDelivery                    wire.SteerDelivery                    `json:"steerDelivery"`
	RetryDelivery                    wire.RetryDelivery                    `json:"retryDelivery"`
	Interrupt                        wire.Interrupt                        `json:"interrupt"`
	Stop                             wire.Stop                             `json:"stop"`
	Continue                         wire.Continue                         `json:"continue"`
	Respond                          wire.Respond                          `json:"respond"`
	StopItem                         wire.StopItem                         `json:"stopItem"`
	InstanceInfo                     wire.InstanceInfo                     `json:"instanceInfo"`
	AuthenticationResult             wire.AuthenticationResult             `json:"authenticationResult"`
	SessionSummary                   wire.SessionSummary                   `json:"sessionSummary"`
	Attachment                       wire.Attachment                       `json:"attachment"`
	PromptAnnotation                 wire.PromptAnnotation                 `json:"promptAnnotation"`
	ConfigOption                     wire.ConfigOption                     `json:"configOption"`
	ConfigChoice                     wire.ConfigChoice                     `json:"configChoice"`
	ConfigOptionSelection            wire.ConfigOptionSelection            `json:"configOptionSelection"`
	SlashCommand                     wire.SlashCommand                     `json:"slashCommand"`
	ProviderCompleteCommandParams    wire.ProviderCompleteCommandParams    `json:"providerCompleteCommandParams"`
	CommandCompletion                wire.CommandCompletion                `json:"commandCompletion"`
	Skill                            wire.Skill                            `json:"skill"`
	TokenUsage                       wire.TokenUsage                       `json:"tokenUsage"`
	Goal                             wire.Goal                             `json:"goal"`
	RequestAction                    wire.RequestAction                    `json:"requestAction"`
	Entry                            wire.Entry                            `json:"entry"`
	Envelope                         wire.Envelope                         `json:"envelope"`
	RequestRecord                    wire.RequestRecord                    `json:"requestRecord"`
	Workspace                        wire.Workspace                        `json:"workspace"`
	PlanEntry                        wire.PlanEntry                        `json:"planEntry"`
	ProviderStartParams              wire.ProviderStartParams              `json:"providerStartParams"`
	ACPRegistryStartParams           wire.ACPRegistryStartParams           `json:"aCPRegistryStartParams"`
	ProviderAuthenticateParams       wire.ProviderAuthenticateParams       `json:"providerAuthenticateParams"`
	ProviderInstanceParams           wire.ProviderInstanceParams           `json:"providerInstanceParams"`
	ProviderListSessionsParams       wire.ProviderListSessionsParams       `json:"providerListSessionsParams"`
	ProviderSessionParams            wire.ProviderSessionParams            `json:"providerSessionParams"`
	ProviderOptionsGetParams         wire.ProviderOptionsGetParams         `json:"providerOptionsGetParams"`
	ProviderOptionsSetParams         wire.ProviderOptionsSetParams         `json:"providerOptionsSetParams"`
	ProviderOptionsResult            wire.ProviderOptionsResult            `json:"providerOptionsResult"`
	ProviderOptionsInvalidated       wire.ProviderOptionsInvalidated       `json:"providerOptionsInvalidated"`
	ProviderQuestion                 wire.ProviderQuestion                 `json:"providerQuestion"`
	ProviderQuestionAnswerParams     wire.ProviderQuestionAnswerParams     `json:"providerQuestionAnswerParams"`
	ACPRegistryAgent                 wire.ACPRegistryAgent                 `json:"aCPRegistryAgent"`
	ACPRegistryInstalledAgent        wire.ACPRegistryInstalledAgent        `json:"aCPRegistryInstalledAgent"`
	ACPRegistryInstallParams         wire.ACPRegistryInstallParams         `json:"aCPRegistryInstallParams"`
	ACPCustomAgentAddParams          wire.ACPCustomAgentAddParams          `json:"aCPCustomAgentAddParams"`
	TerminalSummary                  wire.TerminalSummary                  `json:"terminalSummary"`
	TerminalAttachResult             wire.TerminalAttachResult             `json:"terminalAttachResult"`
	TerminalStreamSnapshot           wire.TerminalStreamSnapshot           `json:"terminalStreamSnapshot"`
	TerminalStreamResized            wire.TerminalStreamResized            `json:"terminalStreamResized"`
	TerminalStreamExited             wire.TerminalStreamExited             `json:"terminalStreamExited"`
	TerminalListStreamItem           wire.TerminalListStreamItem           `json:"terminalListStreamItem"`
	TerminalRenameParams             wire.TerminalRenameParams             `json:"terminalRenameParams"`
	TerminalCreateParams             wire.TerminalCreateParams             `json:"terminalCreateParams"`
	TerminalIDParams                 wire.TerminalIDParams                 `json:"terminalIDParams"`
	TerminalAttachParams             wire.TerminalAttachParams             `json:"terminalAttachParams"`
	TerminalRelaunchParams           wire.TerminalRelaunchParams           `json:"terminalRelaunchParams"`
	TerminalDetachParams             wire.TerminalDetachParams             `json:"terminalDetachParams"`
	TerminalWriteParams              wire.TerminalWriteParams              `json:"terminalWriteParams"`
	TerminalResizeParams             wire.TerminalResizeParams             `json:"terminalResizeParams"`
	WorkspaceBrowseDirectoriesParams wire.WorkspaceBrowseDirectoriesParams `json:"workspaceBrowseDirectoriesParams"`
	WorkspaceDirectoryEntry          wire.WorkspaceDirectoryEntry          `json:"workspaceDirectoryEntry"`
	WorkspaceBrowseDirectoriesResult wire.WorkspaceBrowseDirectoriesResult `json:"workspaceBrowseDirectoriesResult"`
	WorkspaceSearchFilesParams       wire.WorkspaceSearchFilesParams       `json:"workspaceSearchFilesParams"`
	WorkspaceFileEntry               wire.WorkspaceFileEntry               `json:"workspaceFileEntry"`
	WorkspaceSearchFilesResult       wire.WorkspaceSearchFilesResult       `json:"workspaceSearchFilesResult"`
}

func main() {
	out := flag.String("out", "api/generated/client-api.schema.json", "schema output path")
	methodsOut := flag.String("methods-out", "api/generated/rpc-methods.json", "method registry output path")
	vocabularyOut := flag.String("vocabulary-out", "api/generated/vocabulary.json", "closed string vocabulary output path")
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

	writeJSON(*out, schema)
	writeJSON(*methodsOut, struct {
		Methods       []wire.MethodDefinition       `json:"methods"`
		Notifications []wire.NotificationDefinition `json:"notifications"`
	}{wire.Methods, wire.Notifications})
	// Closed string vocabularies are emitted separately: the JSON Schema
	// reflector sees only `string` for Go named-string constants, so without
	// this every client would re-type the literals by hand.
	writeJSON(*vocabularyOut, struct {
		Vocabularies []wire.VocabularyDefinition `json:"vocabularies"`
	}{wire.Vocabularies})
}

// writeJSON writes v as indented JSON with a trailing newline.
func writeJSON(path string, v any) {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		fatal(err)
	}
	data = append(data, '\n')
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		fatal(err)
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
