import CoreGraphics
import CoreText
import Foundation

/// Draws a `TextLayout` into a top-down context, on any thread: glyphs with
/// `CTFontDrawGlyphs` per run (the run's font and positions from layout, as
/// the flipped text matrix wants them),
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
                // lands in the bitmap); runs keep y negated to match.
                run.glyphs.withUnsafeBufferPointer { glyphs in
                    run.positions.withUnsafeBufferPointer { positions in
                        guard let glyphs = glyphs.baseAddress, let positions = positions.baseAddress else { return }
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
            case .taskUnchecked:
                let box = decoration.rect.insetBy(dx: 0.75, dy: 0.75)
                context.setStrokeColor(palette.secondary)
                context.setLineWidth(1.25)
                context.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
                context.strokePath()
            case .taskChecked:
                let box = decoration.rect.insetBy(dx: 0.75, dy: 0.75)
                let boxPath = CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil)
                context.setFillColor(palette.inlineCodeBackground)
                context.addPath(boxPath)
                context.fillPath()
                context.setStrokeColor(palette.primary)
                context.setLineWidth(1.25)
                context.addPath(boxPath)
                context.strokePath()
                context.setStrokeColor(palette.primary)
                context.setLineWidth(1.6)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                let r = decoration.rect
                context.beginPath()
                context.move(to: CGPoint(x: r.minX + r.width * 0.25, y: r.minY + r.height * 0.52))
                context.addLine(to: CGPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.70))
                context.addLine(to: CGPoint(x: r.minX + r.width * 0.75, y: r.minY + r.height * 0.30))
                context.strokePath()
            case .underline, .strikethrough:
                guard let color = palette.color(decoration.color) else { continue }
                context.setFillColor(color)
                context.fill(decoration.rect)
            }
        }
    }
}
