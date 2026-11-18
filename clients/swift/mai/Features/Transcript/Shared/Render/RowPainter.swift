import CoreGraphics
import Foundation

/// Draws the part of a row's content inside `clip` (row coordinates) into a
/// top-down context, from its layout alone: any thread. Fills that belong to
/// the row's shape (bubbles, code and notice backgrounds) are layer
/// properties instead, so they cost no bitmap and never redraw (PLAN 4.5).
nonisolated enum RowPainter {
    static func draw(
        _ content: RowContentLayout, clip: CGRect, palette: TextPalette, drawsWideBody: Bool, in context: CGContext
    ) {
        switch content {
        case .text(let layout, let origin):
            TextRenderer.draw(layout, at: origin, clip: clip, palette: palette, in: context)
        case .bubble(let layout, _, let textOrigin):
            TextRenderer.draw(layout, at: textOrigin, clip: clip, palette: palette, in: context)
        case .notice(let layout, let frame, let textOrigin):
            TextRenderer.draw(
                layout, at: CGPoint(x: frame.minX + textOrigin.x, y: textOrigin.y), clip: clip, palette: palette,
                in: context)
        case .header(let layout, let origin, let dividerY):
            TextRenderer.draw(layout, at: origin, clip: clip, palette: palette, in: context)
            context.setFillColor(palette.separator)
            context.fill(CGRect(x: 0, y: dividerY, width: clip.maxX, height: 1))
        case .code(let layout, let frame):
            let labelOrigin = CGPoint(x: frame.minX + layout.bodyOrigin.x, y: frame.minY + layout.labelTop)
            TextRenderer.draw(layout.label, at: labelOrigin, clip: clip, palette: palette, in: context)
            if drawsWideBody {
                context.saveGState()
                context.clip(to: CGRect(x: frame.minX, y: frame.minY + layout.headerHeight, width: frame.width, height: frame.height - layout.headerHeight))
                TextRenderer.draw(
                    layout.body, at: CGPoint(x: frame.minX + layout.bodyOrigin.x, y: frame.minY + layout.bodyOrigin.y),
                    clip: clip, palette: palette, in: context)
                context.restoreGState()
            }
        case .codeBody(let layout):
            TextRenderer.draw(
                layout.body, at: CGPoint(x: layout.bodyOrigin.x, y: 0), clip: clip, palette: palette, in: context)
        case .table(let layout, let frame):
            if drawsWideBody {
                drawGrid(
                    layout, origin: CGPoint(x: frame.minX, y: frame.minY + layout.toolbarHeight), width: frame.width,
                    clip: clip, palette: palette, in: context)
            }
        case .tableBody(let layout):
            drawGrid(
                layout, origin: .zero, width: layout.gridSize.width, clip: clip, palette: palette, in: context)
        case .actions, .empty:
            break
        }
    }

    /// A table's grid with its top left at `origin`, clipped to `width`.
    private static func drawGrid(
        _ layout: TableLayout, origin: CGPoint, width: CGFloat, clip: CGRect, palette: TextPalette,
        in context: CGContext
    ) {
        let gridTop = origin.y
        context.saveGState()
        context.clip(to: CGRect(x: origin.x, y: gridTop, width: width, height: layout.gridSize.height))
        context.setFillColor(palette.separator)
        // Hairlines on the pixel grid.
        let scale = max(1, context.ctm.a)
        for divider in layout.dividers {
            let rect = divider.offsetBy(dx: origin.x, dy: gridTop)
            guard rect.intersects(clip) else { continue }
            context.fill(CGRect(x: rect.minX, y: (rect.minY * scale).rounded() / scale, width: rect.width, height: 1 / scale))
        }
        for cell in layout.cells {
            let cellOrigin = CGPoint(x: origin.x + cell.origin.x, y: gridTop + cell.origin.y)
            guard cellOrigin.y < clip.maxY, cellOrigin.y + cell.layout.size.height > clip.minY else { continue }
            TextRenderer.draw(cell.layout, at: cellOrigin, clip: clip, palette: palette, in: context)
        }
        context.restoreGState()
    }
}
