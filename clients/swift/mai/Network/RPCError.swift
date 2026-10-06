import Foundation

struct RPCError: LocalizedError {
    let code: Int?
    let message: String
    let data: JSONAny?

    var errorDescription: String? {
        if let code {
            return "\(message) (\(code))"
        }
        return message
    }
}

extension RPCError {
    /// A client-side failure with no daemon error code or data.
    init(_ message: String) {
        self.init(code: nil, message: message, data: nil)
    }
}
