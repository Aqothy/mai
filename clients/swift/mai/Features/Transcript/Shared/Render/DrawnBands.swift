import CoreGraphics

/// Bands of a row drawn off the main thread together with its layout (a
/// streamed block in `TranscriptStreamWorker` or a cold viewport row in
/// `LayoutQueue`), so layout and pixels land on the main thread in one hop.
nonisolated struct DrawnBands: Sendable {
    struct Drawing: Sendable {
        let palette: TextPalette
        let scale: CGFloat
        let colorSpace: CGColorSpace
    }

    /// What they were drawn with; a row showing another palette, scale or
    /// color space draws its bands itself.
    let palette: TextPalette
    let scale: CGFloat
    let colorSpace: CGColorSpace
    /// The outer row's bands that changed, by frame in row coordinates.
    let bands: [(frame: CGRect, bitmap: BandBitmap?)]
    /// The wide body's bands that changed (code or table wider than the row),
    /// in wide-body coordinates, so wide streamed blocks also update atomically.
    let wideBands: [(frame: CGRect, bitmap: BandBitmap?)]

    /// At most the bottom 4 bands (~2,048 pt, > 2 screens) are pre-drawn
    /// inline with a streamed layout. If an off-screen earlier band of a huge
    /// block changed (e.g. a table column widening), `RasterQueue` draws it
    /// off-main only if the reader scrolls back to it.
    private static let maxPreDrawnTailBands = 4
    /// At most the leftmost 2 horizontal tiles (1,536 pt > 2x column width)
    /// are pre-drawn inline for wide streaming blocks; tiles scrolled further
    /// right rasterize lazily via `RasterQueue`.
    private static let maxPreDrawnWideColumns = 2

    /// Pre-draws the leading bands of a freshly laid-out cold row inside the
    /// same `LayoutQueue` worker hop (1-hop raster); each band draws only its
    /// visible lines (`O(band height)`).
    static func drawInitial(
        _ layout: RowLayout, drawing: Drawing, maxBands: Int = 2
    ) -> DrawnBands? {
        guard maxBands > 0 else { return nil }
        let drawsWideBody = layout.content.wideBody == nil
        let bounds = layout.content.paintedBounds(
            drawsWideBody: drawsWideBody, rowWidth: layout.key.width, rowHeight: layout.height)
        let frames = RowLayer.bandFrames(in: bounds)
        var bands: [(frame: CGRect, bitmap: BandBitmap?)] = []
        for frame in frames.prefix(maxBands) {
            let raster = BandRaster(
                content: layout.content, palette: drawing.palette, drawsWideBody: drawsWideBody, rect: frame,
                scale: drawing.scale, colorSpace: drawing.colorSpace)
            bands.append((frame, BandRasterizer.bitmap(raster)))
        }
        var wideBands: [(frame: CGRect, bitmap: BandBitmap?)] = []
        if let wide = layout.content.wideBody {
            let wideBounds = wide.content.paintedBounds(
                drawsWideBody: true, rowWidth: wide.contentWidth, rowHeight: wide.frame.height)
            if !wideBounds.isEmpty {
                let rowCount = min(maxBands, Int(ceil(wideBounds.height / RowLayer.bandHeight)))
                let colCount = min(maxPreDrawnWideColumns, Int(ceil(wideBounds.width / RowLayer.bandWidth)))
                for row in 0..<rowCount {
                    let top = wideBounds.minY + CGFloat(row) * RowLayer.bandHeight
                    let h = min(RowLayer.bandHeight, wideBounds.maxY - top)
                    for col in 0..<colCount {
                        let left = wideBounds.minX + CGFloat(col) * RowLayer.bandWidth
                        let frame = CGRect(
                            x: left, y: top, width: min(RowLayer.bandWidth, wideBounds.maxX - left), height: h)
                        let raster = BandRaster(
                            content: wide.content, palette: drawing.palette, drawsWideBody: true, rect: frame,
                            scale: drawing.scale, colorSpace: drawing.colorSpace)
                        wideBands.append((frame, BandRasterizer.bitmap(raster)))
                    }
                }
            }
        }
        guard !bands.isEmpty || !wideBands.isEmpty else { return nil }
        return DrawnBands(
            palette: drawing.palette, scale: drawing.scale, colorSpace: drawing.colorSpace,
            bands: bands, wideBands: wideBands)
    }

    /// Draws the bands of `layout` that do not draw as they did in
    /// `previous`, the layout the row showed before.
    static func draw(
        _ layout: RowLayout, after previous: RowLayout?, palette: TextPalette, scale: CGFloat,
        colorSpace: CGColorSpace
    ) -> DrawnBands {
        let drawsWideBody = layout.content.wideBody == nil
        let bounds = layout.content.paintedBounds(
            drawsWideBody: drawsWideBody, rowWidth: layout.key.width, rowHeight: layout.height)
        let unchanged = previous.map { RowContentDiff.unchangedHeight($0.content, layout.content) } ?? 0
        let oldFrames: [CGRect] = previous.map {
            let oldBounds = $0.content.paintedBounds(
                drawsWideBody: $0.content.wideBody == nil, rowWidth: $0.key.width, rowHeight: $0.height)
            return RowLayer.bandFrames(in: oldBounds)
        } ?? []
        let frames = RowLayer.bandFrames(in: bounds)
        let firstTailIndex = max(0, frames.count - maxPreDrawnTailBands)
        var bands: [(frame: CGRect, bitmap: BandBitmap?)] = []
        for index in firstTailIndex..<frames.count {
            let frame = frames[index]
            if index < oldFrames.count, oldFrames[index] == frame, frame.maxY <= unchanged { continue }
            let raster = BandRaster(
                content: layout.content, palette: palette, drawsWideBody: drawsWideBody, rect: frame,
                scale: scale, colorSpace: colorSpace)
            bands.append((frame, BandRasterizer.bitmap(raster)))
        }
        var wideBands: [(frame: CGRect, bitmap: BandBitmap?)] = []
        if let wide = layout.content.wideBody {
            let wideBounds = wide.content.paintedBounds(
                drawsWideBody: true, rowWidth: wide.contentWidth, rowHeight: wide.frame.height)
            if !wideBounds.isEmpty {
                let previousWide = previous?.content.wideBody
                let previousWideBounds = previousWide.map {
                    $0.content.paintedBounds(drawsWideBody: true, rowWidth: $0.contentWidth, rowHeight: $0.frame.height)
                }
                let wideUnchanged =
                    previousWide.map { RowContentDiff.unchangedHeight($0.content, wide.content) } ?? 0
                let rowCount = Int(ceil(wideBounds.height / RowLayer.bandHeight))
                let colCount = Int(ceil(wideBounds.width / RowLayer.bandWidth))
                let firstRow = max(0, rowCount - maxPreDrawnTailBands)
                let preDrawnCols = min(colCount, maxPreDrawnWideColumns)
                for row in firstRow..<rowCount {
                    let top = wideBounds.minY + CGFloat(row) * RowLayer.bandHeight
                    let h = min(RowLayer.bandHeight, wideBounds.maxY - top)
                    for col in 0..<preDrawnCols {
                        let left = wideBounds.minX + CGFloat(col) * RowLayer.bandWidth
                        let frame = CGRect(
                            x: left, y: top, width: min(RowLayer.bandWidth, wideBounds.maxX - left), height: h)
                        if let previousWideBounds,
                            previousWideBounds.origin == wideBounds.origin,
                            top < previousWideBounds.maxY,
                            left < previousWideBounds.maxX,
                            min(RowLayer.bandHeight, previousWideBounds.maxY - top) == frame.height,
                            min(RowLayer.bandWidth, previousWideBounds.maxX - left) == frame.width,
                            frame.maxY <= wideUnchanged
                        {
                            continue
                        }
                        let raster = BandRaster(
                            content: wide.content, palette: palette, drawsWideBody: true, rect: frame, scale: scale,
                            colorSpace: colorSpace)
                        wideBands.append((frame, BandRasterizer.bitmap(raster)))
                    }
                }
            }
        }
        return DrawnBands(palette: palette, scale: scale, colorSpace: colorSpace, bands: bands, wideBands: wideBands)
    }

    /// A view of `wideBands` shaped as a `DrawnBands` for the wide body's `RowLayer`.
    var wideBodyDrawn: DrawnBands? {
        guard !wideBands.isEmpty else { return nil }
        return DrawnBands(
            palette: palette, scale: scale, colorSpace: colorSpace, bands: wideBands, wideBands: [])
    }
}
