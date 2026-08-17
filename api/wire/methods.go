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
	{Name: MethodOrchestrationDispatchCommand, Params: "Command", Result: "DispatchResult"},
	{Name: MethodOrchestrationSubscribeThreadList, Params: "EmptyParams", Result: "ThreadListStreamItem"},
	{Name: MethodOrchestrationSubscribeThread, Params: "SubscribeThreadInput", Result: "ThreadStreamItem"},
	{Name: MethodOrchestrationUnsubscribeThread, Params: "SubscribeThreadInput", ResultNull: true},
	{Name: MethodOrchestrationGetItemDetail, Params: "GetItemDetailInput", Result: "Item"},
	{Name: MethodProviderStart, Params: "ProviderStartParams", Result: "InstanceInfo"},
	{Name: MethodProviderList, Params: "EmptyParams", Result: "InstanceInfo", ResultArray: true},
	{Name: MethodACPRegistryList, Params: "EmptyParams", Result: "ACPRegistryAgent", ResultArray: true},
	{Name: MethodACPRegistryInstalled, Params: "EmptyParams", Result: "ACPRegistryInstalledAgent", ResultArray: true},
	{Name: MethodACPRegistryInstall, Params: "ACPRegistryInstallParams", Result: "ACPRegistryInstalledAgent"},
	{Name: MethodACPRegistryAddCustom, Params: "ACPCustomAgentAddParams", Result: "ACPRegistryInstalledAgent"},
	{Name: MethodACPRegistryStart, Params: "ACPRegistryStartParams", Result: "InstanceInfo"},
	{Name: MethodProviderAuthenticate, Params: "ProviderAuthenticateParams", Result: "InstanceInfo"},
	{Name: MethodProviderLogout, Params: "ProviderInstanceParams", Result: "InstanceInfo"},
	{Name: MethodProviderListSessions, Params: "ProviderListSessionsParams", Result: "SessionSummary", ResultArray: true},
	{Name: MethodProviderImportSession, Params: "ProviderImportSessionParams", Result: "ProviderImportSessionResult"},
	{Name: MethodProviderDeleteSession, Params: "ProviderSessionParams", ResultNull: true},
	{Name: MethodProviderCloseSession, Params: "ProviderSessionParams", ResultNull: true},
	{Name: MethodProviderOptionsGet, Params: "ProviderOptionsGetParams", Result: "ProviderOptionsResult"},
	{Name: MethodProviderOptionsSet, Params: "ProviderOptionsSetParams", Result: "ProviderOptionsResult"},
	{Name: MethodTerminalCreate, Params: "TerminalCreateParams", Result: "TerminalAttachSnapshot"},
	{Name: MethodTerminalAttach, Params: "TerminalAttachParams", Result: "TerminalAttachSnapshot"},
	{Name: MethodTerminalRelaunch, Params: "TerminalAttachParams", Result: "TerminalAttachSnapshot"},
	{Name: MethodTerminalSubscribeList, Params: "EmptyParams", Result: "TerminalListStreamItem"},
	{Name: MethodTerminalRename, Params: "TerminalRenameParams", Result: "TerminalSummary"},
	{Name: MethodTerminalTerminate, Params: "TerminalIDParams", ResultNull: true},
	{Name: MethodTerminalDelete, Params: "TerminalIDParams", ResultNull: true},
	// Clients send terminal.write, terminal.resize, and terminal.detach as
	// notifications; they are registered here so generated clients can name
	// them.
	{Name: MethodTerminalWrite, Params: "TerminalWriteParams", ResultNull: true},
	{Name: MethodTerminalResize, Params: "TerminalResizeParams", ResultNull: true},
	{Name: MethodTerminalDetach, Params: "TerminalDetachParams", ResultNull: true},
	{Name: MethodWorkspaceBrowseDirectories, Params: "WorkspaceBrowseDirectoriesParams", Result: "WorkspaceBrowseDirectoriesResult"},
	{Name: MethodWorkspaceSearchFiles, Params: "WorkspaceSearchFilesParams", Result: "WorkspaceSearchFilesResult"},
}

var Notifications = []NotificationDefinition{
	{Name: MethodOrchestrationSubscribeThreadList, Payload: "ThreadListStreamItem"},
	{Name: MethodOrchestrationSubscribeThread, Payload: "ThreadStreamItem"},
	{Name: MethodProviderOptionsUpdated, Payload: "ProviderOptionsResult"},
	{Name: MethodProviderOptionsInvalidated, Payload: "ProviderOptionsInvalidated"},
	{Name: MethodTerminalSubscribe, Payload: "TerminalStreamItem"},
	{Name: MethodTerminalSubscribeList, Payload: "TerminalListStreamItem"},
}
