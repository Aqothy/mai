import CoreGraphics
import Foundation

/// One fitted line of a `TextLayout` (top-down layout coordinates).
/// Holds only geometry and its UTF-16 range (~64 bytes); glyphs, carets, and
/// inline decorations are computed on demand strictly for visible or queried
/// lines (`REDESIGN.md §4, §9`).
nonisolated struct TextLine: Equatable, Sendable {
    let top: CGFloat
    let baseline: CGFloat
    let height: CGFloat
    /// Where the line starts (its indent, or right-aligned origin for RTL) and
    /// its visible width without trailing whitespace.
    let x: CGFloat
    let width: CGFloat
    /// The UTF-16 range of the layout's text on this line.
    let range: Range<Int>
    /// Index into `PreparedText.paragraphs`.
    let paragraphIndex: Int
    /// Vertical gap above this line (`lineSpacing + spacingBefore` when starting
    /// a subsequent paragraph), used to connect quote bars across line gaps.
    let gapAbove: CGFloat
    /// True for the first visual line of its `StyledParagraph` (task markers).
    let isParagraphStart: Bool
    /// The line ends at a hard break (newline), so the caret after that
    /// character starts the next line.
    let endsWithNewline: Bool
    /// True when any `StyledRun` overlapping `range` carries inline code,
    /// underline, strikethrough, or a link.
    let hasInlineDecorations: Bool
    /// For unwrapped pure-ASCII code lines: byte range in `PreparedText.text`
    /// excluding trailing `\r`/`\n`, enabling O(visible columns) horizontal
    /// slicing and O(1) hit-testing even on multi-MB single lines.
    let fastASCIIByteRange: Range<Int>?
    let hasTabs: Bool
    /// UAX #9 BiDi base writing direction of the hard sub-paragraph containing
    /// this line, passed to `CTParagraphStyle` when shaping/drawing BiDi lines
    /// standalone so wrapped continuation lines preserve paragraph BiDi order.
    let bidiIsRTL: Bool

    init(
        top: CGFloat, baseline: CGFloat, height: CGFloat, x: CGFloat, width: CGFloat, range: Range<Int>,
        paragraphIndex: Int = 0, gapAbove: CGFloat = 0, isParagraphStart: Bool = false, endsWithNewline: Bool,
        hasInlineDecorations: Bool = false, fastASCIIByteRange: Range<Int>? = nil, hasTabs: Bool = false,
        bidiIsRTL: Bool = false
    ) {
        self.top = top
        self.baseline = baseline
        self.height = height
        self.x = x
        self.width = width
        self.range = range
        self.paragraphIndex = paragraphIndex
        self.gapAbove = gapAbove
        self.isParagraphStart = isParagraphStart
        self.endsWithNewline = endsWithNewline
        self.hasInlineDecorations = hasInlineDecorations
        self.fastASCIIByteRange = fastASCIIByteRange
        self.hasTabs = hasTabs
        self.bidiIsRTL = bidiIsRTL
    }

    var bottom: CGFloat { top + height }
}
