@testable import mai

/// Test doubles implement only the RPCs their tests exercise; anything else
/// fails like an unsupported daemon method.
extension ThreadRPCClient {
    private var unavailable: RPCError {
        RPCError("Unavailable in this test double")
    }

    func listProviders() async throws -> [InstanceInfo] { [] }
    func subscribeRegistryList() async throws -> ACPRegistryList { ACPRegistryList(agents: []) }
    func refreshRegistry() async throws -> ACPRegistryList { ACPRegistryList(agents: []) }
    func listProviderSessions(_ input: ProviderListSessionsParams) async throws -> [SessionSummary] { [] }
    func subscribeProjectList() async throws -> ProjectList { ProjectList(projects: []) }
    func addProject(_ path: String) async throws -> Project { throw unavailable }
    func removeProject(_ path: String) async throws { throw unavailable }

    func unsubscribeThread(_ threadID: String) async throws {}
    func syncThread(_ threadID: String) async throws {}
    func threadTurns(_ input: ThreadTurnsParams) async throws -> ThreadTurnsResult { throw unavailable }
    func threadEntry(_ input: ThreadEntryParams) async throws -> Entry { throw unavailable }
    func forkPreview(_ input: ThreadForkPreviewParams) async throws -> ForkPreview { throw unavailable }
    func getAttachment(_ id: String) async throws -> Attachment { throw unavailable }
    func answerProviderQuestion(_ input: ProviderQuestionAnswerParams) async throws { throw unavailable }
    func uploadAttachment(_ data: String) async throws -> String { throw unavailable }
    func command(_ params: CommandParams) async throws -> CommandResult { throw unavailable }
    func installRegistryAgent(_ registryID: String) async throws { throw unavailable }
    func updateCustomACPAgent(_ input: ACPCustomAgentUpdateParams) async throws -> ACPRegistryAgent {
        throw unavailable
    }
    func removeInstalledAgent(_ registryID: String) async throws { throw unavailable }
    func addCustomACPAgent(_ input: ACPCustomAgentAddParams) async throws -> ACPRegistryAgent {
        throw unavailable
    }
    func startProvider(_ instanceID: String) async throws -> InstanceInfo { throw unavailable }
    func startRegistryAgent(_ registryID: String, cwd: String?) async throws -> InstanceInfo {
        throw unavailable
    }
    func authenticateProvider(_ input: ProviderAuthenticateParams) async throws -> AuthenticationResult {
        throw unavailable
    }
    func logoutProvider(_ input: ProviderInstanceParams) async throws -> InstanceInfo { throw unavailable }
    func deleteProviderSession(_ input: ProviderSessionParams) async throws { throw unavailable }
    func getProviderOptions(_ input: ProviderOptionsGetParams) async throws -> ProviderOptionsResult {
        throw unavailable
    }
    func setProviderOption(_ input: ProviderOptionsSetParams) async throws -> ProviderOptionsResult {
        throw unavailable
    }
    func browseWorkspaceDirectories(
        _ input: WorkspaceBrowseDirectoriesParams
    ) async throws -> WorkspaceBrowseDirectoriesResult { throw unavailable }
    func searchWorkspaceFiles(_ input: WorkspaceSearchFilesParams) async throws -> WorkspaceSearchFilesResult {
        throw unavailable
    }
    func completeCommand(_ input: ProviderCompleteCommandParams) async throws -> [CommandCompletion] { [] }
}
