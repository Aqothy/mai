import Foundation

/// Terminal-thread RPC surface. Kept separate from ThreadRPCClient so the
/// terminal store can own an independent connection whose lifecycle never
/// affects agent-thread streaming.
protocol TerminalRPCClient: AnyObject {
    var onTerminalStreamItem: ((TerminalStreamMessage) -> Void)? { get set }
    var onTerminalListItem: ((TerminalListStreamItem) -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }

    func connect()
    func disconnect()

    /// Returns the full snapshot and registers this connection for
    /// subsequent list notifications.
    func subscribeTerminalList() async throws -> TerminalListStreamItem
    func renameTerminal(_ params: TerminalRenameParams) async throws -> TerminalSummary
    func deleteTerminal(terminalID: String) async throws

    func createTerminal(_ params: TerminalCreateParams) async throws -> TerminalAttachSnapshot
    func attachTerminal(_ params: TerminalAttachParams) async throws -> TerminalAttachSnapshot
    func relaunchTerminal(_ params: TerminalAttachParams) async throws -> TerminalAttachSnapshot
    func terminateTerminal(terminalID: String) async throws

    /// Fire-and-forget input bytes; the transport preserves call order.
    func writeTerminal(_ params: TerminalWriteParams)

    /// Fire-and-forget grid change; sent only when rows or columns differ.
    func resizeTerminal(_ params: TerminalResizeParams)

    /// Fire-and-forget detach; the shell keeps running on the daemon.
    func detachTerminal(_ params: TerminalDetachParams)
}

// Default implementations let test doubles override only what they exercise.
extension TerminalRPCClient {
    func subscribeTerminalList() async throws -> TerminalListStreamItem {
        throw RPCError(code: nil, message: "Terminal list is unavailable", data: nil)
    }

    func renameTerminal(_ params: TerminalRenameParams) async throws -> TerminalSummary {
        throw RPCError(code: nil, message: "Terminal rename is unavailable", data: nil)
    }

    func deleteTerminal(terminalID: String) async throws {
        throw RPCError(code: nil, message: "Terminal deletion is unavailable", data: nil)
    }

    func createTerminal(_ params: TerminalCreateParams) async throws -> TerminalAttachSnapshot {
        throw RPCError(code: nil, message: "Terminal creation is unavailable", data: nil)
    }

    func attachTerminal(_ params: TerminalAttachParams) async throws -> TerminalAttachSnapshot {
        throw RPCError(code: nil, message: "Terminal attach is unavailable", data: nil)
    }

    func relaunchTerminal(_ params: TerminalAttachParams) async throws -> TerminalAttachSnapshot {
        throw RPCError(code: nil, message: "Terminal relaunch is unavailable", data: nil)
    }

    func terminateTerminal(terminalID: String) async throws {
        throw RPCError(code: nil, message: "Terminal termination is unavailable", data: nil)
    }

    func writeTerminal(_ params: TerminalWriteParams) {}

    func resizeTerminal(_ params: TerminalResizeParams) {}

    func detachTerminal(_ params: TerminalDetachParams) {}
}

extension RPCClient: TerminalRPCClient {
    func subscribeTerminalList() async throws -> TerminalListStreamItem {
        try await call(MaidRPCMethod.terminalSubscribeList, params: EmptyParams())
    }

    func renameTerminal(_ params: TerminalRenameParams) async throws -> TerminalSummary {
        try await call(MaidRPCMethod.terminalRename, params: params)
    }

    func deleteTerminal(terminalID: String) async throws {
        try await callVoid(
            MaidRPCMethod.terminalDelete,
            params: TerminalIDParams(terminalID: terminalID)
        )
    }

    func createTerminal(_ params: TerminalCreateParams) async throws -> TerminalAttachSnapshot {
        try await call(MaidRPCMethod.terminalCreate, params: params)
    }

    func attachTerminal(_ params: TerminalAttachParams) async throws -> TerminalAttachSnapshot {
        try await call(MaidRPCMethod.terminalAttach, params: params)
    }

    func relaunchTerminal(_ params: TerminalAttachParams) async throws -> TerminalAttachSnapshot {
        try await call(MaidRPCMethod.terminalRelaunch, params: params)
    }

    func terminateTerminal(terminalID: String) async throws {
        try await callVoid(
            MaidRPCMethod.terminalTerminate,
            params: TerminalIDParams(terminalID: terminalID)
        )
    }

    func writeTerminal(_ params: TerminalWriteParams) {
        notify(MaidRPCMethod.terminalWrite, params: params)
    }

    func resizeTerminal(_ params: TerminalResizeParams) {
        notify(MaidRPCMethod.terminalResize, params: params)
    }

    func detachTerminal(_ params: TerminalDetachParams) {
        notify(MaidRPCMethod.terminalDetach, params: params)
    }
}
