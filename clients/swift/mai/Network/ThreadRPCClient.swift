import Foundation

protocol ThreadRPCClient: RPCTransportClient {
    var onNotification: ((String, Data) -> Void)? { get set }
    func subscribeThreadList() async throws -> ThreadListItem
    func subscribeProjectList() async throws -> ProjectList
    func addProject(_ path: String) async throws -> Project
    func removeProject(_ path: String) async throws
    func subscribeThread(_ threadID: String) async throws -> ThreadSnapshot
    func unsubscribeThread(_ threadID: String) async throws
    func syncThread(_ threadID: String) async throws
    func threadTurns(_ input: ThreadTurnsParams) async throws -> ThreadTurnsResult
    func threadEntry(_ input: ThreadEntryParams) async throws -> Entry
    func forkPreview(_ input: ThreadForkPreviewParams) async throws -> ForkPreview
    func getAttachment(_ id: String) async throws -> Attachment
    func uploadAttachment(_ data: String) async throws -> String
    func command(_ params: CommandParams) async throws -> CommandResult
    func listProviders() async throws -> [InstanceInfo]
    func listRegistryAgents() async throws -> [ACPRegistryAgent]
    func listInstalledAgents() async throws -> [ACPRegistryInstalledAgent]
    func installRegistryAgent(_ registryID: String) async throws -> ACPRegistryInstalledAgent
    func addCustomACPAgent(_ input: ACPCustomAgentAddParams) async throws -> ACPRegistryInstalledAgent
    func updateCustomACPAgent(_ input: ACPCustomAgentUpdateParams) async throws -> ACPRegistryInstalledAgent
    func removeInstalledAgent(_ registryID: String) async throws
    func startProvider(_ instanceID: String) async throws -> InstanceInfo
    func startRegistryAgent(_ registryID: String, restart: Bool) async throws -> InstanceInfo
    func authenticateProvider(_ input: ProviderAuthenticateParams) async throws
        -> AuthenticationResult
    func logoutProvider(_ input: ProviderInstanceParams) async throws -> InstanceInfo
    func listProviderSessions(_ input: ProviderListSessionsParams) async throws -> [SessionSummary]
    func deleteProviderSession(_ input: ProviderSessionParams) async throws
    func getProviderOptions(_ input: ProviderOptionsGetParams) async throws -> ProviderOptionsResult
    func setProviderOption(_ input: ProviderOptionsSetParams) async throws -> ProviderOptionsResult
    func answerProviderQuestion(_ input: ProviderQuestionAnswerParams) async throws
    func browseWorkspaceDirectories(
        _ input: WorkspaceBrowseDirectoriesParams
    ) async throws -> WorkspaceBrowseDirectoriesResult
    func searchWorkspaceFiles(_ input: WorkspaceSearchFilesParams) async throws -> WorkspaceSearchFilesResult
    func completeCommand(_ input: ProviderCompleteCommandParams) async throws -> [CommandCompletion]
}

extension RPCClient: ThreadRPCClient {
    func subscribeThreadList() async throws -> ThreadListItem {
        try await call(MaidRPCMethod.threadSubscribeList, params: EmptyParams())
    }

    func subscribeProjectList() async throws -> ProjectList {
        try await call(MaidRPCMethod.projectSubscribeList, params: EmptyParams())
    }

    func addProject(_ path: String) async throws -> Project {
        try await call(MaidRPCMethod.projectAdd, params: ProjectParams(path: path))
    }

    func removeProject(_ path: String) async throws {
        try await callVoid(MaidRPCMethod.projectRemove, params: ProjectParams(path: path))
    }

    func subscribeThread(_ threadID: String) async throws -> ThreadSnapshot {
        try await call(MaidRPCMethod.threadSubscribe, params: ThreadParams(thread: threadID))
    }

    func unsubscribeThread(_ threadID: String) async throws {
        try await callVoid(MaidRPCMethod.threadUnsubscribe, params: ThreadParams(thread: threadID))
    }

    func syncThread(_ threadID: String) async throws {
        try await callVoid(MaidRPCMethod.threadSync, params: ThreadParams(thread: threadID))
    }

    func threadTurns(_ input: ThreadTurnsParams) async throws -> ThreadTurnsResult {
        try await call(MaidRPCMethod.threadTurns, params: input)
    }

    func forkPreview(_ input: ThreadForkPreviewParams) async throws -> ForkPreview {
        try await call(MaidRPCMethod.threadForkPreview, params: input)
    }

    func threadEntry(_ input: ThreadEntryParams) async throws -> Entry {
        try await call(MaidRPCMethod.threadEntry, params: input)
    }

    func getAttachment(_ id: String) async throws -> Attachment {
        try await call(MaidRPCMethod.attachmentGet, params: AttachmentParams(id: id))
    }

    func uploadAttachment(_ data: String) async throws -> String {
        let result: AttachmentUploadResult = try await call(
            MaidRPCMethod.attachmentUpload,
            params: AttachmentUploadParams(data: data)
        )
        return result.id
    }

    func command(_ params: CommandParams) async throws -> CommandResult {
        try await call(MaidRPCMethod.threadCommand, params: params)
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

    func updateCustomACPAgent(_ input: ACPCustomAgentUpdateParams) async throws -> ACPRegistryInstalledAgent {
        try await call(MaidRPCMethod.acpRegistryUpdateCustom, params: input)
    }

    func removeInstalledAgent(_ registryID: String) async throws {
        try await callVoid(MaidRPCMethod.acpRegistryRemove, params: ACPRegistryRemoveParams(registryID: registryID))
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

    func authenticateProvider(_ input: ProviderAuthenticateParams) async throws
        -> AuthenticationResult
    {
        try await call(MaidRPCMethod.providerAuthenticate, params: input)
    }

    func logoutProvider(_ input: ProviderInstanceParams) async throws -> InstanceInfo {
        try await call(MaidRPCMethod.providerLogout, params: input)
    }

    func listProviderSessions(_ input: ProviderListSessionsParams) async throws -> [SessionSummary] {
        try await call(MaidRPCMethod.providerListSessions, params: input)
    }

    func deleteProviderSession(_ input: ProviderSessionParams) async throws {
        try await callVoid(MaidRPCMethod.providerDeleteSession, params: input)
    }

    func getProviderOptions(_ input: ProviderOptionsGetParams) async throws -> ProviderOptionsResult {
        try await call(MaidRPCMethod.providerOptionsGet, params: input)
    }

    func setProviderOption(_ input: ProviderOptionsSetParams) async throws -> ProviderOptionsResult {
        try await call(MaidRPCMethod.providerOptionsSet, params: input)
    }

    func answerProviderQuestion(_ input: ProviderQuestionAnswerParams) async throws {
        try await callVoid(MaidRPCMethod.providerQuestionAnswer, params: input)
    }

    func browseWorkspaceDirectories(
        _ input: WorkspaceBrowseDirectoriesParams
    ) async throws -> WorkspaceBrowseDirectoriesResult {
        try await call(MaidRPCMethod.workspaceBrowseDirectories, params: input)
    }

    func searchWorkspaceFiles(_ input: WorkspaceSearchFilesParams) async throws -> WorkspaceSearchFilesResult {
        try await call(MaidRPCMethod.workspaceSearchFiles, params: input)
    }

    func completeCommand(_ input: ProviderCompleteCommandParams) async throws -> [CommandCompletion] {
        try await call(MaidRPCMethod.providerCompleteCommand, params: input)
    }
}
