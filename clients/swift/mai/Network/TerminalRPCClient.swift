import Foundation

/// Terminal-thread RPC surface. Kept separate from ThreadRPCClient so the
/// terminal store can own an independent connection whose lifecycle never
/// affects agent-thread streaming.
protocol TerminalRPCClient: AnyObject {
    var onTerminalStreamItem: ((TerminalStreamMessage) -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }

    func connect()
    func disconnect()

    func createTerminal(_ params: TerminalCreateParams) async throws -> TerminalAttachSnapshot
    func terminateTerminal(terminalID: String) async throws

    /// Fire-and-forget input bytes; the transport preserves call order.
    func writeTerminal(_ params: TerminalWriteParams)

    /// Fire-and-forget grid change; sent only when rows or columns differ.
    func resizeTerminal(_ params: TerminalResizeParams)
}

// Default implementations let test doubles override only what they exercise.
extension TerminalRPCClient {
    func createTerminal(_ params: TerminalCreateParams) async throws -> TerminalAttachSnapshot {
        throw RPCError(code: nil, message: "Terminal creation is unavailable", data: nil)
    }

    func terminateTerminal(terminalID: String) async throws {
        throw RPCError(code: nil, message: "Terminal termination is unavailable", data: nil)
    }

    func writeTerminal(_ params: TerminalWriteParams) {}

    func resizeTerminal(_ params: TerminalResizeParams) {}
}

extension RPCClient: TerminalRPCClient {
    func createTerminal(_ params: TerminalCreateParams) async throws -> TerminalAttachSnapshot {
        try await call(MaidRPCMethod.terminalCreate, params: params)
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
}
