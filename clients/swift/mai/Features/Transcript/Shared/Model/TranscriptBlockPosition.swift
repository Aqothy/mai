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
