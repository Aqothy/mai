import CoreGraphics

/// Bands of a row drawn off the main thread together with its layout (a
/// streamed block, `TranscriptStreamWorker`), so the row shows its new
/// text in the same frame as its new size, never an older bitmap in it.
nonisolated struct DrawnBands: Sendable {
    /// What they were drawn with; a row showing another palette or scale
    /// draws its bands itself.
    let palette: TextPalette
    let scale: CGFloat
    /// The bands that changed, by frame in row coordinates.
    let bands: [(frame: CGRect, bitmap: BandBitmap?)]

    /// Draws the bands of `layout` that do not draw as they did in
    /// `previous`, the layout the row showed before.
    static func draw(
        _ layout: RowLayout, after previous: RowLayout?, palette: TextPalette, scale: CGFloat,
        colorSpace: CGColorSpace
    ) -> DrawnBands {
        let unchanged = previous.map { RowContentDiff.unchangedHeight($0.content, layout.content) } ?? 0
        let oldFrames = previous.map { Self.frames(of: $0) } ?? []
        var bands: [(frame: CGRect, bitmap: BandBitmap?)] = []
        for (index, frame) in Self.frames(of: layout).enumerated() {
            if index < oldFrames.count, oldFrames[index] == frame, frame.maxY <= unchanged { continue }
            let raster = BandRaster(
                content: layout.content, palette: palette, drawsWideBody: layout.content.wideBody == nil, rect: frame,
                scale: scale, colorSpace: colorSpace)
            bands.append((frame, BandRasterizer.bitmap(raster)))
        }
        return DrawnBands(palette: palette, scale: scale, bands: bands)
    }

    /// The bands `RowLayer` gives `layout`'s row.
    private static func frames(of layout: RowLayout) -> [CGRect] {
        let drawsWideBody = layout.content.wideBody == nil
        return RowLayer.bandFrames(
            height: layout.content.paintedHeight(drawsWideBody: drawsWideBody, rowHeight: layout.height),
            width: layout.key.width)
    }
}
