import CoreGraphics
import Foundation

/// Where a block sits in its message, which decides the space around it:
/// the message's inset at its ends, 16 points between prose blocks and 8
/// next to a code block or table (the chat's existing spacing), but for a
/// heading after one: a heading belongs with what follows it.
nonisolated struct TranscriptBlockPosition: Hashable, Sendable {
    var isFirst: Bool
    var isLast: Bool
    /// This block or the one above it is a code block or table.
    var isBesideRichBlock = false

    /// The position of `blocks[index]` in its message.
    static func of(_ index: Int, in blocks: [MarkdownBlock]) -> TranscriptBlockPosition {
        TranscriptBlockPosition(
            isFirst: index == 0, isLast: index == blocks.count - 1,
            isBesideRichBlock: blocks[index].isRich
                || (index > 0 && blocks[index - 1].isRich && !blocks[index].isHeading))
    }

    func spacingAbove(_ style: TextStyle) -> CGFloat {
        if isFirst { return style.messageVerticalInset }
        return isBesideRichBlock ? style.richBlockSpacing : style.blockSpacing
    }

    func spacingBelow(_ style: TextStyle) -> CGFloat {
        isLast ? style.messageVerticalInset : 0
    }
}
