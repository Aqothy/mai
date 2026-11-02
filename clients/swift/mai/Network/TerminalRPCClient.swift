import Foundation

/// Terminal RPC surface. Thread and terminal stores keep separate domain
/// protocols while sharing one RPCClient and connection lifecycle.
protocol TerminalRPCClient: RPCTransportClient {
    var onTerminalListItem: ((TerminalListStreamItem) -> Void)? { get set }

    /// Returns the full snapshot and registers this connection for
    /// subsequent list notifications.
    func subscribeTerminalList() async throws -> TerminalListStreamItem
    func renameTerminal(_ params: TerminalRenameParams) async throws -> TerminalSummary
    func deleteTerminal(terminalID: String) async throws

    /// Each returns a ticket for the view's terminal stream.
    func createTerminal(_ params: TerminalCreateParams) async throws -> TerminalAttachResult
    func attachTerminal(_ params: TerminalAttachParams) async throws -> TerminalAttachResult
    func relaunchTerminal(_ params: TerminalRelaunchParams) async throws -> TerminalAttachResult

    /// Where views open their terminal streams, beside the RPC endpoint.
    var terminalStreamEndpoint: URL { get }

    /// Fire-and-forget input bytes; the transport preserves call order.
    func writeTerminal(_ params: TerminalWriteParams)

    /// Fire-and-forget report of the grid and appearance that fit a view.
    func resizeTerminal(_ params: TerminalResizeParams)

    /// Fire-and-forget: the user is using this view, which takes the size.
    func focusTerminal(terminalID: String)

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

    func createTerminal(_ params: TerminalCreateParams) async throws -> TerminalAttachResult {
        try await call(MaidRPCMethod.terminalCreate, params: params)
    }

    func attachTerminal(_ params: TerminalAttachParams) async throws -> TerminalAttachResult {
        try await call(MaidRPCMethod.terminalAttach, params: params)
    }

    func relaunchTerminal(_ params: TerminalRelaunchParams) async throws -> TerminalAttachResult {
        try await call(MaidRPCMethod.terminalRelaunch, params: params)
    }

    func writeTerminal(_ params: TerminalWriteParams) {
        notify(MaidRPCMethod.terminalWrite, params: params)
    }

    func resizeTerminal(_ params: TerminalResizeParams) {
        notify(MaidRPCMethod.terminalResize, params: params)
    }

    func focusTerminal(terminalID: String) {
        notify(MaidRPCMethod.terminalFocus, params: TerminalIDParams(terminalID: terminalID))
    }

    func detachTerminal(_ params: TerminalDetachParams) {
        notify(MaidRPCMethod.terminalDetach, params: params)
    }
}
