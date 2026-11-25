import CoreGraphics
import Foundation

/// Where a block sits in its message, which decides the space around it:
/// the message's inset at its ends, `TextStyle.blockSpacing` between blocks
/// of every kind. Oversized blocks split into multiple rows set `joinsAbove` /
/// `joinsBelow` so adjacent chunks flow together seamlessly.
nonisolated struct TranscriptBlockPosition: Hashable, Sendable {
    var isFirst: Bool
    var isLast: Bool
    var joinsAbove: Bool = false
    var joinsBelow: Bool = false
    /// A joined chunk of a user message that starts a Markdown block (the
    /// message split at a blank line): the seam takes the block spacing.
    var startsBlock = false
    /// The widest line of the whole split code block this chunk belongs to,
    /// in monospace columns (0 when not split): every chunk scrolls over the
    /// same width, as one `<pre>` does. Exact for the code font's own glyphs
    /// and tabs (`TextStyle.codeTabInterval`); a fallback font's wide glyph
    /// counts two columns, which CJK runs a fifth under and emoji a tenth
    /// over, so such a block can scroll a little past its text, or one chunk
    /// a little further than the rest.
    var widestLineColumns = 0

    static let single = TranscriptBlockPosition(isFirst: true, isLast: true)

    /// The position of `blocks[index]` in its message.
    static func of(_ index: Int, in blocks: [MarkdownBlock]) -> TranscriptBlockPosition {
        TranscriptBlockPosition(isFirst: index == 0, isLast: index == blocks.count - 1)
    }

    func spacingAbove(_ style: TextStyle, forCode: Bool = false) -> CGFloat {
        if joinsAbove { return forCode ? 0 : style.lineSpacing }
        return isFirst ? style.messageVerticalInset : style.blockSpacing
    }

    func spacingBelow(_ style: TextStyle) -> CGFloat {
        if joinsBelow { return 0 }
        return isLast ? style.messageVerticalInset : 0
    }
}
