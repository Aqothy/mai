import CoreGraphics
import Foundation

/// One laid-out line, in layout coordinates (top-down).
nonisolated struct TextLine: Sendable {
    /// The line's top and its baseline.
    let top: CGFloat
    let baseline: CGFloat
    let height: CGFloat
    /// Where the line starts (its indent) and its width without trailing
    /// whitespace.
    let x: CGFloat
    let width: CGFloat
    /// The UTF-16 range of the layout's text on this line.
    let range: Range<Int>
    /// The caret's x for each UTF-16 offset from `range.lowerBound` through
    /// `range.upperBound`, from Core Text (`CTLineEnumerateCaretOffsets`):
    /// hit testing and selection rects without the line object.
    let caretOffsets: [CGFloat]
    /// The runs of `TextLayout.runs` on this line.
    let runs: Range<Int>
    /// The decorations of `TextLayout.decorations` emitted for this line.
    let decorations: Range<Int>
    /// The line ends at a hard break (its last character is a newline), so
    /// the caret after that character starts the next line.
    let endsWithNewline: Bool

    var bottom: CGFloat { top + height }
}
