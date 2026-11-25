import CoreGraphics
import Foundation

/// Glyphs of one font and style, copied out of a `CTRun` so they can be
/// drawn on any thread. Positions are as `CTFontDrawGlyphs` takes them under
/// `TextRenderer`'s flipped text matrix: layout x, and the negated layout y
/// of the baseline, so drawing needs no copy.
nonisolated struct TextGlyphRun: Sendable {
    let font: TranscriptFont
    let glyphs: [CGGlyph]
    let positions: [CGPoint]
    let color: TextColor
    /// The UTF-16 range of the layout's text the run draws.
    let range: Range<Int>
    /// Index into the layout's links, for hit testing a click or tap.
    let linkIndex: Int?
    /// Set on runs inside complex BiDi lines so selection rects split cleanly
    /// per visual run without jumping across LTR/RTL boundaries.
    let isRightToLeft: Bool
    let visualWidth: CGFloat

    init(
        font: TranscriptFont, glyphs: [CGGlyph], positions: [CGPoint], color: TextColor, range: Range<Int>,
        linkIndex: Int?, isRightToLeft: Bool = false, visualWidth: CGFloat = 0
    ) {
        self.font = font
        self.glyphs = glyphs
        self.positions = positions
        self.color = color
        self.range = range
        self.linkIndex = linkIndex
        self.isRightToLeft = isRightToLeft
        self.visualWidth = visualWidth
    }
}
