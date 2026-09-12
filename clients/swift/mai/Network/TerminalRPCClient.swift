import Foundation

/// Terminal RPC surface. Thread and terminal stores keep separate domain
/// protocols while sharing one RPCClient and connection lifecycle.
protocol TerminalRPCClient: RPCTransportClient {
    var onTerminalStreamItem: ((TerminalStreamMessage) -> Void)? { get set }
    var onTerminalListItem: ((TerminalListStreamItem) -> Void)? { get set }

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
