package wire

// MethodDefinition links a JSON-RPC method to named schemas in the generated
// contract. It is metadata for client generation; handlers still own behavior.
type MethodDefinition struct {
	Name        string `json:"name"`
	Params      string `json:"params"`
	Result      string `json:"result,omitempty"`
	ResultArray bool   `json:"resultArray,omitempty"`
	ResultNull  bool   `json:"resultNull,omitempty"`
}

// NotificationDefinition describes a server-initiated JSON-RPC notification.
type NotificationDefinition struct {
	Name    string `json:"name"`
	Payload string `json:"payload"`
}

// Methods is the canonical typed JSON-RPC method registry used by generators.
var Methods = []MethodDefinition{
	{Name: MethodThreadCommand, Params: "CommandParams", Result: "CommandResult"},
	{Name: MethodThreadSubscribeList, Params: "EmptyParams", Result: "ThreadListItem"},
	{Name: MethodThreadSubscribe, Params: "ThreadParams", Result: "ThreadSnapshot"},
	{Name: MethodThreadUnsubscribe, Params: "ThreadParams", ResultNull: true},
	{Name: MethodThreadSync, Params: "ThreadParams", ResultNull: true},
	{Name: MethodThreadTurns, Params: "ThreadTurnsParams", Result: "ThreadTurnsResult"},
	{Name: MethodThreadEntry, Params: "ThreadEntryParams", Result: "Entry"},
	{Name: MethodThreadForkPreview, Params: "ThreadForkPreviewParams", Result: "ForkPreview"},
	{Name: MethodAttachmentUpload, Params: "AttachmentUploadParams", Result: "AttachmentUploadResult"},
	{Name: MethodAttachmentGet, Params: "AttachmentParams", Result: "Attachment"},
	{Name: MethodProviderStart, Params: "ProviderStartParams", Result: "InstanceInfo"},
	{Name: MethodProviderList, Params: "EmptyParams", Result: "InstanceInfo", ResultArray: true},
	{Name: MethodACPRegistryList, Params: "EmptyParams", Result: "ACPRegistryAgent", ResultArray: true},
	{Name: MethodACPRegistryInstalled, Params: "EmptyParams", Result: "ACPRegistryInstalledAgent", ResultArray: true},
	{Name: MethodACPRegistryInstall, Params: "ACPRegistryInstallParams", Result: "ACPRegistryInstalledAgent"},
	{Name: MethodACPRegistryAddCustom, Params: "ACPCustomAgentAddParams", Result: "ACPRegistryInstalledAgent"},
	{Name: MethodACPRegistryStart, Params: "ACPRegistryStartParams", Result: "InstanceInfo"},
	{Name: MethodProviderAuthenticate, Params: "ProviderAuthenticateParams", Result: "AuthenticationResult"},
	{Name: MethodProviderLogout, Params: "ProviderInstanceParams", Result: "InstanceInfo"},
	{Name: MethodProviderListSessions, Params: "ProviderListSessionsParams", Result: "SessionSummary", ResultArray: true},
	{Name: MethodProviderDeleteSession, Params: "ProviderSessionParams", ResultNull: true},
	{Name: MethodProviderOptionsGet, Params: "ProviderOptionsGetParams", Result: "ProviderOptionsResult"},
	{Name: MethodProviderCompleteCommand, Params: "ProviderCompleteCommandParams", Result: "CommandCompletion", ResultArray: true},
	{Name: MethodProviderOptionsSet, Params: "ProviderOptionsSetParams", Result: "ProviderOptionsResult"},
	{Name: MethodProviderQuestionAnswer, Params: "ProviderQuestionAnswerParams", ResultNull: true},
	{Name: MethodTerminalCreate, Params: "TerminalCreateParams", Result: "TerminalAttachResult"},
	{Name: MethodTerminalAttach, Params: "TerminalAttachParams", Result: "TerminalAttachResult"},
	{Name: MethodTerminalRelaunch, Params: "TerminalRelaunchParams", Result: "TerminalAttachResult"},
	{Name: MethodTerminalSubscribeList, Params: "EmptyParams", Result: "TerminalListStreamItem"},
	{Name: MethodTerminalRename, Params: "TerminalRenameParams", Result: "TerminalSummary"},
	{Name: MethodTerminalTerminate, Params: "TerminalIDParams", ResultNull: true},
	{Name: MethodTerminalDelete, Params: "TerminalIDParams", ResultNull: true},
	// Clients send terminal.write, terminal.resize, terminal.focus, and
	// terminal.detach as notifications; they are registered here so generated
	// clients can name them.
	{Name: MethodTerminalWrite, Params: "TerminalWriteParams", ResultNull: true},
	{Name: MethodTerminalResize, Params: "TerminalResizeParams", ResultNull: true},
	{Name: MethodTerminalFocus, Params: "TerminalIDParams", ResultNull: true},
	{Name: MethodTerminalDetach, Params: "TerminalDetachParams", ResultNull: true},
	{Name: MethodWorkspaceBrowseDirectories, Params: "WorkspaceBrowseDirectoriesParams", Result: "WorkspaceBrowseDirectoriesResult"},
	{Name: MethodWorkspaceSearchFiles, Params: "WorkspaceSearchFilesParams", Result: "WorkspaceSearchFilesResult"},
	{Name: MethodProjectAdd, Params: "ProjectParams", Result: "Project"},
	{Name: MethodProjectRemove, Params: "ProjectParams", ResultNull: true},
	{Name: MethodProjectSubscribeList, Params: "EmptyParams", Result: "ProjectList"},
}

var Notifications = []NotificationDefinition{
	{Name: MethodThreadList, Payload: "ThreadListItem"},
	{Name: MethodThreadEvent, Payload: "ThreadEvent"},
	{Name: MethodProviderOptionsUpdated, Payload: "ProviderOptionsResult"},
	{Name: MethodProviderOptionsInvalidated, Payload: "ProviderOptionsInvalidated"},
	{Name: MethodProviderQuestionAsked, Payload: "ProviderQuestion"},
	{Name: MethodTerminalSubscribeList, Payload: "TerminalListStreamItem"},
	{Name: MethodProjectList, Payload: "ProjectList"},
}
