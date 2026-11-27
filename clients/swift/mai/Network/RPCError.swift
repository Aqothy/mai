import Foundation

struct RPCError: LocalizedError {
    let code: Int?
    let message: String
    let data: JSONAny?

    /// JSON-RPC codes of a refused command, whose message is written for
    /// the user.
    private static let refusedCodes: Set<Int> = [-32001, -32602]

    var errorDescription: String? {
        if let code, !Self.refusedCodes.contains(code) {
            return "\(message) (\(code))"
        }
        return message
    }

    /// Why maiD refused a command: its error's `data.code`.
    @MainActor var commandErrorCode: MaidCommandErrorCode? {
        ((data?.value as? [String: Any])?["code"] as? String).flatMap(MaidCommandErrorCode.init(rawValue:))
    }
}

extension RPCError {
    /// A client-side failure with no daemon error code or data.
    init(_ message: String) {
        self.init(code: nil, message: message, data: nil)
    }
}
