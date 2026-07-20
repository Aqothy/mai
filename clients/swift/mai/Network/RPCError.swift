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
