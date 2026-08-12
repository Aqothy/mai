import Foundation
import Synchronization

/// A process-wide cache for uncommon settled fallback prose.
///
/// Ordinary settled assistant prose uses the thread-owned selectable layout
/// cache. Fallback entries remain available for the process lifetime so an
/// unchanged message is never reparsed solely because it left the viewport.
nonisolated final class ChatMarkdownRenderCache: Sendable {
    static let shared = ChatMarkdownRenderCache()

    private struct Entry {
        let source: String
        let attributedString: AttributedString
    }

    private let entries = Mutex<[String: Entry]>([:])

    func attributedString(
        messageID: String,
        source: String
    ) -> AttributedString {
        if let cached = entries.withLock({ entries in
            entries[messageID].flatMap {
                $0.source == source ? $0.attributedString : nil
            }
        }) {
            return cached
        }

        // Conversion stays outside the lock. Different rows can prepare in
        // parallel, and a rare duplicate is better than serializing parsing.
        let rendered = ChatMarkdownAttributedStringRenderer.attributedString(
            from: source
        )

        return entries.withLock { entries in
            if let cached = entries[messageID], cached.source == source {
                return cached.attributedString
            }
            entries[messageID] = Entry(
                source: source,
                attributedString: rendered
            )
            return rendered
        }
    }
}
