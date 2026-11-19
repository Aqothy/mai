import CoreGraphics
import Foundation

/// Where a block sits in its message, which decides the space around it:
/// the message's inset at its ends, `TextStyle.blockSpacing` between blocks
/// of every kind.
nonisolated struct TranscriptBlockPosition: Hashable, Sendable {
    var isFirst: Bool
    var isLast: Bool

    /// The position of `blocks[index]` in its message.
    static func of(_ index: Int, in blocks: [MarkdownBlock]) -> TranscriptBlockPosition {
        TranscriptBlockPosition(isFirst: index == 0, isLast: index == blocks.count - 1)
    }

    func spacingAbove(_ style: TextStyle) -> CGFloat {
        isFirst ? style.messageVerticalInset : style.blockSpacing
    }

    func spacingBelow(_ style: TextStyle) -> CGFloat {
        isLast ? style.messageVerticalInset : 0
    }
}
