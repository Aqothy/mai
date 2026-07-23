import Foundation

protocol ThreadRPCClient: AnyObject {
    var onNotification: ((String, Data) -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }

    func connect()
    func disconnect()
    func subscribeThreadList() async throws -> ThreadListStreamItem
    func subscribeThread(_ input: SubscribeThreadInput) async throws -> ThreadStreamItem
    func unsubscribeThread(_ input: SubscribeThreadInput) async throws
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
}
