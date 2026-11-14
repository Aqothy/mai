import SwiftUI

/// A settled fenced code block whose highlighted, measured text can be
/// prepared before its row is realized.
nonisolated struct ChatCodeLayoutRequest: Sendable {
    let id: String
    let block: ChatMarkdownCodeBlock
    let theme: ChatCodeHighlightTheme
}
