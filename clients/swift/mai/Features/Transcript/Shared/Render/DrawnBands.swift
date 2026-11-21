import CoreGraphics

/// Bands of a row drawn off the main thread together with its layout (a
/// streamed block, `TranscriptStreamWorker`), so the row shows its new
/// text in the same frame as its new size, never an older bitmap in it.
nonisolated struct DrawnBands: Sendable {
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

    /// Draws the bands of `layout` that do not draw as they did in
    /// `previous`, the layout the row showed before.
    static func draw(
        _ layout: RowLayout, after previous: RowLayout?, palette: TextPalette, scale: CGFloat,
        colorSpace: CGColorSpace
    ) -> DrawnBands {
        let drawsWideBody = layout.content.wideBody == nil
        let painted = layout.content.paintedHeight(drawsWideBody: drawsWideBody, rowHeight: layout.height)
        let unchanged = previous.map { RowContentDiff.unchangedHeight($0.content, layout.content) } ?? 0
        let oldPainted = previous.map {
            $0.content.paintedHeight(drawsWideBody: $0.content.wideBody == nil, rowHeight: $0.height)
        } ?? 0
        let oldFrames = previous.map { RowLayer.bandFrames(height: oldPainted, width: $0.key.width) } ?? []
        let frames = RowLayer.bandFrames(height: painted, width: layout.key.width)
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
            let previousWide = previous?.content.wideBody
            let wideUnchanged =
                previousWide.map { RowContentDiff.unchangedHeight($0.content, wide.content) } ?? 0
            let oldWideFrames =
                previousWide.map { RowLayer.bandFrames(height: $0.frame.height, width: $0.contentWidth) } ?? []
            let wideFrames = RowLayer.bandFrames(height: wide.frame.height, width: wide.contentWidth)
            let firstWideTail = max(0, wideFrames.count - maxPreDrawnTailBands)
            for index in firstWideTail..<wideFrames.count {
                let frame = wideFrames[index]
                if index < oldWideFrames.count, oldWideFrames[index] == frame, frame.maxY <= wideUnchanged { continue }
                let raster = BandRaster(
                    content: wide.content, palette: palette, drawsWideBody: true, rect: frame, scale: scale,
                    colorSpace: colorSpace)
                wideBands.append((frame, BandRasterizer.bitmap(raster)))
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
