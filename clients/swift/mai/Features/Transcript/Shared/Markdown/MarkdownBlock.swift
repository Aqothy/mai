import CoreGraphics
import Foundation

/// One Markdown block as plain values, final once parsed: streaming appends
/// blocks, it never changes a finished one.
nonisolated indirect enum MarkdownBlock: Hashable, Sendable {
    case paragraph([MarkdownInline])
    case heading(level: Int, [MarkdownInline])
    case list(MarkdownList)
    case quote([MarkdownBlock])
    /// Fenced or indented code, and block HTML shown as its source.
    case code(language: String?, code: String)
    case table(MarkdownTable)
    /// A thematic break, keeping its source spelling so copied text matches.
    case rule(spelling: String)
}

