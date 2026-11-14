import Foundation

extension ChatNativePreparedRow {
    /// The block a native prepared row shows.
    enum Content: Equatable {
        case prose(ChatTextContent)
        case code(ChatMarkdownCodeBlock)
        case table(ChatMarkdownTable)
    }
}
