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
    /// The line contains right-to-left or Core Text reordered runs whose
    /// per-run `visualWidth` and Core Text caret offsets are populated.
    let hasComplexBiDi: Bool

    init(
        top: CGFloat, baseline: CGFloat, height: CGFloat, x: CGFloat, width: CGFloat, range: Range<Int>,
        caretOffsets: [CGFloat], runs: Range<Int>, decorations: Range<Int>, endsWithNewline: Bool,
        hasComplexBiDi: Bool = false
    ) {
        self.top = top
        self.baseline = baseline
        self.height = height
        self.x = x
        self.width = width
        self.range = range
        self.caretOffsets = caretOffsets
        self.runs = runs
        self.decorations = decorations
        self.endsWithNewline = endsWithNewline
        self.hasComplexBiDi = hasComplexBiDi
    }

    var bottom: CGFloat { top + height }
}
