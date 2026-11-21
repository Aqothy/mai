import QuartzCore

/// One mounted row: background shapes as layer properties (bubble, code
/// block, notice), text in band sublayers whose bitmaps are drawn from the
/// row's layout off the main thread. Mounted rows are recycled; nothing here
/// lays text out.
nonisolated final class RowLayer: CALayer {
    static let bandHeight: CGFloat = 512

    /// The frames of a row's bands, in row coordinates: none for a row that
    /// paints nothing, so it holds no `IOSurface`.
    static func bandFrames(height: CGFloat, width: CGFloat) -> [CGRect] {
        guard height > 0, width > 0 else { return [] }
        let count = Int(ceil(height / bandHeight))
        return (0..<count).map { index in
            let top = CGFloat(index) * bandHeight
            return CGRect(x: 0, y: top, width: width, height: min(bandHeight, height - top))
        }
    }

    private(set) var rowID: String?
    private(set) var layoutKey: RowLayoutKey?
    private(set) var content: RowContentLayout = .empty
    /// A code block or table wider than its row draws its body in a
    /// horizontal scroller instead of here.
    private(set) var drawsWideBody = true
    private var bands: [RowBandLayer] = []
    private let shape = CALayer()
    /// The selection highlight: over the row's background, under its text.
    private let selectionLayer = CAShapeLayer()
    private var selectedRange: Range<Int>?
    private var selectionColor: CGColor?
    private var palette: TextPalette?
    /// The color space the bands draw in: their window's.
    private var bandColorSpace: CGColorSpace?
    /// Placement bookkeeping for `TranscriptRowMounter`.
    var placementStamp = 0
    var placedFrame: CGRect = .null
    var hasWideBlock = false
    var hasAccessories = false
    /// The layout and place the accessories were shown for.
    var accessoriesKey: RowLayoutKey?
    var accessoriesOrigin: CGPoint?

    override init() {
        super.init()
        // Not flipped: flipping is relative to the superlayer, and the row's
        // container is already top-down (flipped on the Mac, the default on
        // iOS); a second flip put shapes upside down within the row.
        shape.isHidden = true
        selectionLayer.isHidden = true
        selectionLayer.actions = [
            "path": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull(), "fillColor": NSNull(),
        ]
        addSublayer(shape)
        addSublayer(selectionLayer)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func action(forKey event: String) -> (any CAAction)? { nil }

    /// Shows `layout` for `rowID`. Bands redraw only when the layout, the
    /// palette, the scale or the color space changed; `drawn` has bitmaps of
    /// the new layout made with them, shown now.
    @MainActor
    func show(
        rowID: String, layout: RowLayout, palette: TextPalette, drawsWideBody: Bool, scale: CGFloat,
        colorSpace: CGColorSpace = RowLayer.colorSpace, drawn: DrawnBands? = nil
    ) {
        let sameRow =
            // Any new palette redraws: Increase Contrast changes colors in
            // the same light or dark appearance.
            self.rowID == rowID && self.palette === palette
            && self.drawsWideBody == drawsWideBody && contentsScale == scale && bandColorSpace == colorSpace
        // Syntax colors arrive as a new layout under the same key (they never
        // change the height), so they count as new content too.
        guard
            !sameRow || layoutKey != layout.key || content.colorsAreDark != layout.content.colorsAreDark
                || content.isHighlighted != layout.content.isHighlighted
        else { return }
        // The same row with new content (a streamed block growing) keeps the
        // bands that still draw the same.
        let unchanged = sameRow ? RowContentDiff.unchangedHeight(content, layout.content) : 0
        self.rowID = rowID
        layoutKey = layout.key
        self.palette = palette
        self.drawsWideBody = drawsWideBody
        contentsScale = scale
        bandColorSpace = colorSpace
        content = layout.content
        configureShape(palette: palette)
        let bitmaps =
            drawn.flatMap {
                $0.palette === palette && $0.scale == scale && $0.colorSpace == colorSpace ? $0.bands : nil
            } ?? []
        configureBands(
            height: layout.content.paintedHeight(drawsWideBody: drawsWideBody, rowHeight: layout.height),
            width: bounds.width, scale: scale, unchangedHeight: unchanged, drawn: bitmaps)
        if selectedRange != nil { drawSelection() }
    }

    /// Highlights `range` of the row's text (nil: none). A wide block's body
    /// highlights in its scroller instead.
    func showSelection(_ range: Range<Int>?, color: CGColor) {
        guard range != selectedRange || color != selectionColor else { return }
        selectedRange = range
        selectionColor = color
        drawSelection()
    }

    private func drawSelection() {
        guard let range = selectedRange, let color = selectionColor, drawsWideBody || content.wideBody == nil else {
            selectionLayer.isHidden = true
            selectionLayer.path = nil
            return
        }
        let path = CGMutablePath()
        for rect in content.selectionRects(for: range) { path.addRect(rect) }
        selectionLayer.frame = bounds
        selectionLayer.fillColor = color
        selectionLayer.path = path
        selectionLayer.isHidden = false
    }

    /// The color space bands draw in when their host has not said its
    /// window's: Core Animation color-matches a bitmap in any other than the
    /// display's on the main thread, so hosts pass their window's.
    nonisolated static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Draws the bands crossing `rect` (row coordinates) that do not show
    /// their current bitmap: off the main thread, nearest to `visible` first,
    /// each keeping what it shows until its new bitmap lands. A band on screen
    /// with nothing to show yet is drawn now instead (PLAN D3), as is every
    /// band when `offMain` is off. Returns how many were drawn now.
    @MainActor
    @discardableResult
    func drawBands(in rect: CGRect, visible: CGRect, offMain: Bool) -> Int {
        guard let palette else { return 0 }
        var drawnNow = 0
        for band in bands where !band.isCurrent && band.frame.intersects(rect) {
            // On screen with nothing to show, even if its job is queued.
            let drawsNow = !offMain || (band.contents == nil && band.frame.intersects(visible))
            guard drawsNow || !band.isPending else { continue }
            let raster = BandRaster(
                content: content, palette: palette, drawsWideBody: drawsWideBody, rect: band.frame,
                scale: contentsScale, colorSpace: bandColorSpace ?? Self.colorSpace)
            if drawsNow {
                band.show(BandRasterizer.bitmap(raster), generation: band.generation)
                drawnNow += 1
            } else {
                let distance = max(0, band.frame.minY - visible.maxY, visible.minY - band.frame.maxY)
                RasterQueue.shared.submit(band, raster: raster, priority: distance)
            }
        }
        return drawnNow
    }

    /// Releases bitmaps of bands far from `rect` (row coordinates).
    @MainActor
    func releaseBands(outside rect: CGRect) {
        for band in bands where (band.contents != nil || band.isPending) && !band.frame.intersects(rect) {
            band.release()
        }
    }

    @MainActor
    func resetForReuse() {
        rowID = nil
        layoutKey = nil
        content = .empty
        bandColorSpace = nil
        placedFrame = .null
        hasWideBlock = false
        hasAccessories = false
        accessoriesKey = nil
        accessoriesOrigin = nil
        selectedRange = nil
        selectionLayer.isHidden = true
        selectionLayer.path = nil
        for band in bands { band.release() }
        shape.isHidden = true
    }

    @MainActor
    private func configureBands(
        height: CGFloat, width: CGFloat, scale: CGFloat, unchangedHeight: CGFloat,
        drawn: [(frame: CGRect, bitmap: BandBitmap?)]
    ) {
        let frames = Self.bandFrames(height: height, width: width)
        while bands.count < frames.count {
            let band = RowBandLayer()
            bands.append(band)
            addSublayer(band)
        }
        while bands.count > frames.count { bands.removeLast().removeFromSuperlayer() }
        for (band, frame) in zip(bands, frames) {
            if let bitmap = drawn.first(where: { $0.frame == frame })?.bitmap {
                band.frame = frame
                band.contentsScale = scale
                band.invalidate()
                band.show(bitmap, generation: band.generation)
                continue
            }
            if band.isCurrent || band.isPending, band.frame.minY == frame.minY, band.frame.height == frame.height,
                frame.maxY <= unchangedHeight
            {
                // Draws the same: at another width (the lines broke where
                // they did) it keeps its bitmap, pinned top left.
                if band.frame.width != frame.width { band.frame = frame }
                continue
            }
            // The old bitmap stays until the new one lands: no blank frame.
            if band.frame != frame { band.frame = frame }
            band.contentsScale = scale
            band.invalidate()
        }
    }

    private func configureShape(palette: TextPalette) {
        switch content {
        case .bubble(_, let frame, _):
            shape.isHidden = false
            shape.frame = frame
            shape.backgroundColor = palette.bubble
            shape.cornerRadius = TextStyle.bubbleCornerRadius
            shape.borderWidth = 0
        case .code(_, let frame):
            shape.isHidden = false
            shape.frame = frame
            shape.backgroundColor = palette.codeBackground
            shape.cornerRadius = TextStyle.codeCornerRadius
            shape.borderWidth = 1
            shape.borderColor = palette.codeBorder
        case .notice(_, let frame, _):
            shape.isHidden = false
            shape.frame = frame
            shape.backgroundColor = palette.warning
            shape.cornerRadius = TextStyle.noticeCornerRadius
            shape.borderWidth = 0
        default:
            shape.isHidden = true
        }
    }
}
