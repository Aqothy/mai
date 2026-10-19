import Foundation

/// Decoded terminal notification used by the hot transport path.
///
/// `Data` lets `JSONDecoder` perform the wire's base64 decoding off the main
/// actor, before the message reaches observable UI state.
nonisolated struct TerminalStreamMessage: Decodable, Sendable {
    /// The grid of a resized item.
    let columns: Int?
    let data: Data?
    let exitCode: Int?
    let kind: String
    let message: String?
    let runID: String?
    let rows: Int?
    let sequence: Int?
    let status: String?
    let terminalID: String

    enum CodingKeys: String, CodingKey {
        case columns, data, exitCode, kind, message, rows
        case runID = "runId"
        case sequence, status
        case terminalID = "terminalId"
    }
}
