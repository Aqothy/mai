import CoreGraphics
import Foundation

/// A run of inline text with one style.
nonisolated struct MarkdownInline: Hashable, Sendable {
    struct Style: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let emphasis = Style(rawValue: 1 << 0)
        static let strong = Style(rawValue: 1 << 1)
        static let code = Style(rawValue: 1 << 2)
        static let strikethrough = Style(rawValue: 1 << 3)
    }

    var text: String
    var style: Style = []
    /// Only links the link policy allows; others render as plain text.
    var link: URL?
}
