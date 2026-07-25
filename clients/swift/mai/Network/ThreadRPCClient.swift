import Foundation

protocol ThreadRPCClient: AnyObject {
    var onNotification: ((String, Data) -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }

    func connect()
    func disconnect()
    func subscribeThreadList() async throws -> ThreadListStreamItem
    func subscribeThread(_ input: SubscribeThreadInput) async throws -> ThreadStreamItem
    func unsubscribeThread(_ input: SubscribeThreadInput) async throws
    func listProviders() async throws -> [InstanceInfo]
    func listRegistryAgents() async throws -> [ACPRegistryAgent]
    func startProvider(_ instanceID: String) async throws -> InstanceInfo
    func startRegistryAgent(_ registryID: String) async throws -> InstanceInfo
    func getProviderOptions(_ input: ProviderOptionsGetParams) async throws -> ProviderOptionsResult
    func setProviderOption(_ input: ProviderOptionsSetParams) async throws -> ProviderOptionsResult
    func dispatchCommand(_ command: Command) async throws -> DispatchResult
}

extension ThreadRPCClient {
    func listProviders() async throws -> [InstanceInfo] { [] }
    func listRegistryAgents() async throws -> [ACPRegistryAgent] { [] }

    func startProvider(_ instanceID: String) async throws -> InstanceInfo {
        throw RPCError(code: nil, message: "Provider startup is unavailable", data: nil)
    }

    func startRegistryAgent(_ registryID: String) async throws -> InstanceInfo {
        throw RPCError(code: nil, message: "Agent startup is unavailable", data: nil)
    }

    func getProviderOptions(_ input: ProviderOptionsGetParams) async throws -> ProviderOptionsResult {
        throw RPCError(code: nil, message: "Provider settings are unavailable", data: nil)
    }

    func setProviderOption(_ input: ProviderOptionsSetParams) async throws -> ProviderOptionsResult {
        throw RPCError(code: nil, message: "Provider settings are unavailable", data: nil)
    }

    func dispatchCommand(_ command: Command) async throws -> DispatchResult {
        throw RPCError(code: nil, message: "Command dispatch is unavailable", data: nil)
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

    func listProviders() async throws -> [InstanceInfo] {
        try await call(MaidRPCMethod.providerList, params: EmptyParams())
    }

    func listRegistryAgents() async throws -> [ACPRegistryAgent] {
        try await call(MaidRPCMethod.acpRegistryList, params: EmptyParams())
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

    func startRegistryAgent(_ registryID: String) async throws -> InstanceInfo {
        try await call(
            MaidRPCMethod.acpRegistryStart,
            params: ACPRegistryStartParams(registryID: registryID, restart: nil)
        )
    }

    func getProviderOptions(_ input: ProviderOptionsGetParams) async throws -> ProviderOptionsResult {
        try await call(MaidRPCMethod.providerOptionsGet, params: input)
    }

    func setProviderOption(_ input: ProviderOptionsSetParams) async throws -> ProviderOptionsResult {
        try await call(MaidRPCMethod.providerOptionsSet, params: input)
    }

    func dispatchCommand(_ command: Command) async throws -> DispatchResult {
        try await call(MaidRPCMethod.orchestrationDispatchCommand, params: command)
    }
}
