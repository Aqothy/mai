import Foundation

/// Decoded terminal notification used by the hot transport path.
///
/// `Data` lets `JSONDecoder` perform the wire's base64 decoding off the main
/// actor, before the message reaches observable UI state.
nonisolated struct TerminalStreamMessage: Decodable, Sendable {
    let data: Data?
    let exitCode: Int?
    let kind: String
    let message: String?
    let runID: String?
    let sequence: Int?
    let status: String?
    let terminalID: String

    enum CodingKeys: String, CodingKey {
        case data, exitCode, kind, message
        case runID = "runId"
        case sequence, status
        case terminalID = "terminalId"
    }
}
