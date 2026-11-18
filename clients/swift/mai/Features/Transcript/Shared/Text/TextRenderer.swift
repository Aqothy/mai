import CoreGraphics
import CoreText
import Foundation

/// Draws a `TextLayout` into a top-down context, on any thread: glyphs with
/// `CTFontDrawGlyphs` per run (the run's font and positions from layout),
/// decorations with Core Graphics. Only the lines crossing `clip` are drawn.
nonisolated enum TextRenderer {
    static func draw(
        _ layout: TextLayout, at origin: CGPoint, clip: CGRect, palette: TextPalette, in context: CGContext
    ) {
        let local = clip.offsetBy(dx: -origin.x, dy: -origin.y)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        drawDecorations(layout, behindText: true, clip: local, palette: palette, in: context)
        for line in layout.lines(overlapping: local.minY, local.maxY) {
            for index in line.runs {
                let run = layout.runs[index]
                guard let color = palette.color(run.color) else { continue }
                context.setFillColor(color)
                // Core Text maps glyph positions through the text matrix
                // (checked: with the flip and unchanged positions nothing
                // lands in the bitmap), so y is negated to cancel the flip.
                withUnsafeTemporaryAllocation(of: CGPoint.self, capacity: run.positions.count) { flipped in
                    for (index, position) in run.positions.enumerated() {
                        flipped[index] = CGPoint(x: position.x, y: -position.y)
                    }
                    run.glyphs.withUnsafeBufferPointer { glyphs in
                        guard let glyphs = glyphs.baseAddress, let positions = flipped.baseAddress else { return }
                        CTFontDrawGlyphs(run.font.font, glyphs, positions, run.glyphs.count, context)
                    }
                }
            }
        }
        drawDecorations(layout, behindText: false, clip: local, palette: palette, in: context)
        context.restoreGState()
    }

    private static func drawDecorations(
        _ layout: TextLayout, behindText: Bool, clip: CGRect, palette: TextPalette, in context: CGContext
    ) {
        for decoration in layout.decorations where decoration.isBehindText == behindText {
            guard decoration.rect.intersects(clip) else { continue }
            switch decoration.kind {
            case .inlineCodeBackground:
                context.setFillColor(palette.inlineCodeBackground)
                context.addPath(CGPath(roundedRect: decoration.rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
                context.fillPath()
            case .quoteBar:
                context.setFillColor(palette.tertiary)
                context.fill(decoration.rect)
            case .rule:
                context.setFillColor(palette.separator)
                context.fill(decoration.rect)
            case .underline, .strikethrough:
                guard let color = palette.color(decoration.color) else { continue }
                context.setFillColor(color)
                context.fill(decoration.rect)
            }
        }
    }
}
