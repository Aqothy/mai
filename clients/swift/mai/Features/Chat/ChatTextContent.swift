import SwiftUI

/// What a selectable text view shows: Markdown source rendered on demand, or
/// text a render plan already rendered from its parsed document.
nonisolated enum ChatTextContent: Equatable, Sendable {
    case source(String)
    case rendered(ChatMarkdownText)

    var attributedString: NSAttributedString {
        switch self {
        case .source(let source):
            ChatMarkdownTextRenderer.attributedString(from: source)
        case .rendered(let text):
            text.value
        }
    }

    var utf8Count: Int {
        switch self {
        case .source(let source): source.utf8.count
        case .rendered(let text): text.string.utf8.count
        }
    }
}
