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
	{Name: MethodOrchestrationReplayEvents, Params: "ReplayEventsInput", Result: "Event", ResultArray: true},
	{Name: MethodOrchestrationSubscribeThreadList, Params: "EmptyParams", Result: "ThreadListStreamItem"},
	{Name: MethodOrchestrationSubscribeThread, Params: "SubscribeThreadInput", Result: "ThreadStreamItem"},
	{Name: MethodOrchestrationUnsubscribeThread, Params: "SubscribeThreadInput", ResultNull: true},
	{Name: MethodProviderStart, Params: "ProviderStartParams", Result: "InstanceInfo"},
	{Name: MethodProviderList, Params: "EmptyParams", Result: "InstanceInfo", ResultArray: true},
	{Name: MethodACPRegistryList, Params: "EmptyParams", Result: "ACPRegistryAgent", ResultArray: true},
	{Name: MethodACPRegistryStart, Params: "ACPRegistryStartParams", Result: "InstanceInfo"},
	{Name: MethodProviderAuthenticate, Params: "ProviderAuthenticateParams", Result: "InstanceInfo"},
	{Name: MethodProviderLogout, Params: "ProviderInstanceParams", Result: "InstanceInfo"},
	{Name: MethodProviderListSessions, Params: "ProviderListSessionsParams", Result: "SessionSummary", ResultArray: true},
	{Name: MethodProviderImportSession, Params: "ProviderImportSessionParams", Result: "ProviderImportSessionResult"},
	{Name: MethodProviderDeleteSession, Params: "ProviderSessionParams", ResultNull: true},
	{Name: MethodProviderCloseSession, Params: "ProviderSessionParams", ResultNull: true},
}

var Notifications = []NotificationDefinition{
	{Name: MethodOrchestrationSubscribeThreadList, Payload: "ThreadListStreamItem"},
	{Name: MethodOrchestrationSubscribeThread, Payload: "ThreadStreamItem"},
}
