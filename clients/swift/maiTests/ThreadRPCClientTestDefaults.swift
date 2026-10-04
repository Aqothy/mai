@testable import mai

/// Test doubles implement only the RPCs their tests exercise; anything else
/// fails like an unsupported daemon method.
extension ThreadRPCClient {
    private var unavailable: RPCError {
        RPCError(code: nil, message: "Unavailable in this test double", data: nil)
    }

    func listProviders() async throws -> [InstanceInfo] { [] }
    func listRegistryAgents() async throws -> [ACPRegistryAgent] { [] }
    func listInstalledAgents() async throws -> [ACPRegistryInstalledAgent] { [] }
    func listProviderSessions(_ input: ProviderListSessionsParams) async throws -> [SessionSummary] { [] }

    func getItemDetail(_ input: GetItemDetailInput) async throws -> Item { throw unavailable }
    func installRegistryAgent(_ registryID: String) async throws -> ACPRegistryInstalledAgent {
        throw unavailable
    }
    func addCustomACPAgent(_ input: ACPCustomAgentAddParams) async throws -> ACPRegistryInstalledAgent {
        throw unavailable
    }
    func startProvider(_ instanceID: String) async throws -> InstanceInfo { throw unavailable }
    func startRegistryAgent(_ registryID: String, restart: Bool) async throws -> InstanceInfo {
        throw unavailable
    }
    func authenticateProvider(_ input: ProviderAuthenticateParams) async throws -> AuthenticationResult {
        throw unavailable
    }
    func logoutProvider(_ input: ProviderInstanceParams) async throws -> InstanceInfo { throw unavailable }
    func importProviderSession(_ input: ProviderImportSessionParams) async throws
        -> ProviderImportSessionResult
    { throw unavailable }
    func forkProviderThread(_ input: ProviderForkThreadParams) async throws -> ProviderImportSessionResult {
        throw unavailable
    }
    func deleteProviderSession(_ input: ProviderSessionParams) async throws { throw unavailable }
    func closeProviderSession(_ input: ProviderSessionParams) async throws { throw unavailable }
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
    func dispatchCommand(_ command: Command) async throws -> DispatchResult { throw unavailable }
}
