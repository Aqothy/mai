import Foundation

protocol ThreadRPCClient: RPCTransportClient {
    var onNotification: ((String, Data) -> Void)? { get set }
    func subscribeThreadList() async throws -> ThreadListStreamItem
    func subscribeThread(_ input: SubscribeThreadInput) async throws -> ThreadStreamItem
    func unsubscribeThread(_ input: SubscribeThreadInput) async throws
    func getItemDetail(_ input: GetItemDetailInput) async throws -> Item
    func listProviders() async throws -> [InstanceInfo]
    func listRegistryAgents() async throws -> [ACPRegistryAgent]
    func listInstalledAgents() async throws -> [ACPRegistryInstalledAgent]
    func installRegistryAgent(_ registryID: String) async throws -> ACPRegistryInstalledAgent
    func addCustomACPAgent(_ input: ACPCustomAgentAddParams) async throws -> ACPRegistryInstalledAgent
    func startProvider(_ instanceID: String) async throws -> InstanceInfo
    func startRegistryAgent(_ registryID: String, restart: Bool) async throws -> InstanceInfo
    func listProviderSessions(_ input: ProviderListSessionsParams) async throws -> [SessionSummary]
    func importProviderSession(_ input: ProviderImportSessionParams) async throws -> ProviderImportSessionResult
    func getProviderOptions(_ input: ProviderOptionsGetParams) async throws -> ProviderOptionsResult
    func setProviderOption(_ input: ProviderOptionsSetParams) async throws -> ProviderOptionsResult
    func browseWorkspaceDirectories(
        _ input: WorkspaceBrowseDirectoriesParams
    ) async throws -> WorkspaceBrowseDirectoriesResult
    func searchWorkspaceFiles(_ input: WorkspaceSearchFilesParams) async throws -> WorkspaceSearchFilesResult
    func dispatchCommand(_ command: Command) async throws -> DispatchResult
}

extension ThreadRPCClient {
    func listProviders() async throws -> [InstanceInfo] { [] }
    func listRegistryAgents() async throws -> [ACPRegistryAgent] { [] }
    func listInstalledAgents() async throws -> [ACPRegistryInstalledAgent] { [] }

    func installRegistryAgent(_ registryID: String) async throws -> ACPRegistryInstalledAgent {
        throw RPCError(code: nil, message: "Agent installation is unavailable", data: nil)
    }

    func addCustomACPAgent(_ input: ACPCustomAgentAddParams) async throws -> ACPRegistryInstalledAgent {
        throw RPCError(code: nil, message: "Adding custom agents is unavailable", data: nil)
    }

    func startProvider(_ instanceID: String) async throws -> InstanceInfo {
        throw RPCError(code: nil, message: "Provider startup is unavailable", data: nil)
    }

    func startRegistryAgent(_ registryID: String, restart: Bool) async throws -> InstanceInfo {
        throw RPCError(code: nil, message: "Agent startup is unavailable", data: nil)
    }

    func listProviderSessions(_ input: ProviderListSessionsParams) async throws -> [SessionSummary] { [] }

    func importProviderSession(_ input: ProviderImportSessionParams) async throws -> ProviderImportSessionResult {
        throw RPCError(code: nil, message: "Session import is unavailable", data: nil)
    }

    func getProviderOptions(_ input: ProviderOptionsGetParams) async throws -> ProviderOptionsResult {
        throw RPCError(code: nil, message: "Provider settings are unavailable", data: nil)
    }

    func setProviderOption(_ input: ProviderOptionsSetParams) async throws -> ProviderOptionsResult {
        throw RPCError(code: nil, message: "Provider settings are unavailable", data: nil)
    }

    func browseWorkspaceDirectories(
        _ input: WorkspaceBrowseDirectoriesParams
    ) async throws -> WorkspaceBrowseDirectoriesResult {
        throw RPCError(code: nil, message: "Workspace folder browsing is unavailable", data: nil)
    }

    func searchWorkspaceFiles(_ input: WorkspaceSearchFilesParams) async throws -> WorkspaceSearchFilesResult {
        throw RPCError(code: nil, message: "Workspace file search is unavailable", data: nil)
    }

    func dispatchCommand(_ command: Command) async throws -> DispatchResult {
        throw RPCError(code: nil, message: "Command dispatch is unavailable", data: nil)
    }

    func getItemDetail(_ input: GetItemDetailInput) async throws -> Item {
        throw RPCError(code: nil, message: "Item details are unavailable", data: nil)
    }
}

extension RPCClient: ThreadRPCClient {
    func subscribeThreadList() async throws -> ThreadListStreamItem {
        try await call(
            MaidRPCMethod.orchestrationSubscribeThreadList,
            params: EmptyParams()
        )
    }

    func subscribeThread(_ input: SubscribeThreadInput) async throws -> ThreadStreamItem {
        try await call(
            MaidRPCMethod.orchestrationSubscribeThread,
            params: input
        )
    }

    func unsubscribeThread(_ input: SubscribeThreadInput) async throws {
        try await callVoid(
            MaidRPCMethod.orchestrationUnsubscribeThread,
            params: input
        )
    }

    func getItemDetail(_ input: GetItemDetailInput) async throws -> Item {
        try await call(
            MaidRPCMethod.orchestrationGetItemDetail,
            params: input
        )
    }

    func listProviders() async throws -> [InstanceInfo] {
        try await call(MaidRPCMethod.providerList, params: EmptyParams())
    }

    func listRegistryAgents() async throws -> [ACPRegistryAgent] {
        try await call(MaidRPCMethod.acpRegistryList, params: EmptyParams())
    }

    func listInstalledAgents() async throws -> [ACPRegistryInstalledAgent] {
        try await call(MaidRPCMethod.acpRegistryInstalled, params: EmptyParams())
    }

    func installRegistryAgent(_ registryID: String) async throws -> ACPRegistryInstalledAgent {
        try await call(
            MaidRPCMethod.acpRegistryInstall,
            params: ACPRegistryInstallParams(registryID: registryID)
        )
    }

    func addCustomACPAgent(_ input: ACPCustomAgentAddParams) async throws -> ACPRegistryInstalledAgent {
        try await call(MaidRPCMethod.acpRegistryAddCustom, params: input)
    }

    func startProvider(_ instanceID: String) async throws -> InstanceInfo {
        try await call(
            MaidRPCMethod.providerStart,
            params: ProviderStartParams(
                config: nil,
                driver: nil,
                instanceID: instanceID,
                name: nil,
                restart: nil
            )
        )
    }

    func startRegistryAgent(_ registryID: String, restart: Bool) async throws -> InstanceInfo {
        try await call(
            MaidRPCMethod.acpRegistryStart,
            params: ACPRegistryStartParams(registryID: registryID, restart: restart ? true : nil)
        )
    }

    func listProviderSessions(_ input: ProviderListSessionsParams) async throws -> [SessionSummary] {
        try await call(MaidRPCMethod.providerListSessions, params: input)
    }

    func importProviderSession(_ input: ProviderImportSessionParams) async throws -> ProviderImportSessionResult {
        try await call(MaidRPCMethod.providerImportSession, params: input)
    }

    func getProviderOptions(_ input: ProviderOptionsGetParams) async throws -> ProviderOptionsResult {
        try await call(MaidRPCMethod.providerOptionsGet, params: input)
    }

    func setProviderOption(_ input: ProviderOptionsSetParams) async throws -> ProviderOptionsResult {
        try await call(MaidRPCMethod.providerOptionsSet, params: input)
    }

    func browseWorkspaceDirectories(
        _ input: WorkspaceBrowseDirectoriesParams
    ) async throws -> WorkspaceBrowseDirectoriesResult {
        try await call(MaidRPCMethod.workspaceBrowseDirectories, params: input)
    }

    func searchWorkspaceFiles(_ input: WorkspaceSearchFilesParams) async throws -> WorkspaceSearchFilesResult {
        try await call(MaidRPCMethod.workspaceSearchFiles, params: input)
    }

    func dispatchCommand(_ command: Command) async throws -> DispatchResult {
        try await call(MaidRPCMethod.orchestrationDispatchCommand, params: command)
    }
}
