import Foundation

/// One view's terminal stream: a WebSocket beside the RPC connection that
/// carries the terminal from the daemon as typed records, so output never
/// waits behind (or delays) RPC traffic. The contract is the daemon's
/// `api/wire/terminal.go`: the client sends its attach ticket and nothing
/// else; every later message is one record, a kind byte and its payload.
nonisolated final class TerminalStreamConnection: Sendable {
    /// One record, in stream order.
    enum Record: Sendable {
        /// Starts a snapshot; `size` bytes of snapshot data follow.
        case snapshot(TerminalStreamSnapshot)
        case snapshotData(Data)
        case output(Data)
        case resized(TerminalStreamResized)
    }

    /// How a stream ended.
    enum End: Sendable {
        /// The daemon closed it with this code and reason.
        case closed(URLSessionWebSocketTask.CloseCode, reason: String)
        /// The connection dropped without a close code.
        case dropped
        /// The stream broke the contract, or a record couldn't be applied;
        /// following it further would show the wrong screen.
        case failed(String)
    }

    private static let subprotocol = "maid.terminal.v1"

    private let task: URLSessionWebSocketTask

    init(endpoint: URL) {
        task = URLSession.shared.webSocketTask(with: endpoint, protocols: [Self.subprotocol])
    }

    /// Sends the ticket, then hands each record to `apply` in order, waiting
    /// for each before receiving the next, until the stream ends. Reports
    /// whether a snapshot ever arrived: before one, the view never attached.
    @concurrent
    func run(
        ticket: Data,
        apply: @escaping @Sendable (Record) async throws -> Void
    ) async -> (end: End, sawSnapshot: Bool) {
        task.resume()
        var sawSnapshot = false
        do {
            try await task.send(.data(ticket))
            while true {
                let message = try await task.receive()
                let record = try Self.record(message)
                if case .snapshot = record { sawSnapshot = true }
                do {
                    try await apply(record)
                } catch {
                    throw TerminalStreamError(error.localizedDescription)
                }
            }
        } catch let error as TerminalStreamError {
            task.cancel(with: .protocolError, reason: nil)
            return (.failed(error.message), sawSnapshot)
        } catch {
            guard task.closeCode != .invalid else { return (.dropped, sawSnapshot) }
            let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return (.closed(task.closeCode, reason: reason), sawSnapshot)
        }
    }

    /// Ends the stream from this side; the view is done with it.
    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    private static func record(_ message: URLSessionWebSocketTask.Message) throws -> Record {
        guard case .data(let data) = message, let kind = data.first else {
            throw TerminalStreamError(String(localized: "maiD sent a malformed terminal record."))
        }
        let payload = data.dropFirst()
        func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
            do {
                return try WireJSON.makeDecoder().decode(type, from: payload)
            } catch {
                throw TerminalStreamError(String(localized: "maiD sent a malformed terminal record."))
            }
        }
        switch kind {
        case 0x01: return .snapshot(try decode(TerminalStreamSnapshot.self))
        case 0x02: return .snapshotData(payload)
        case 0x03: return .output(payload)
        case 0x04: return .resized(try decode(TerminalStreamResized.self))
        default:
            // Both sides ship together and the subprotocol names the version,
            // so an unknown record means the screen can't be trusted.
            throw TerminalStreamError(String(localized: "maiD sent an unknown terminal record."))
        }
    }

    /// The ticket's bytes: it is unpadded base64url.
    static func ticketBytes(_ ticket: String) -> Data? {
        var base64 = ticket.replacing("-", with: "+").replacing("_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

nonisolated struct TerminalStreamError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
