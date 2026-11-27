import QuartzCore

/// One mounted row: background shapes as layer properties (bubble, code
/// block, notice), text in band sublayers whose bitmaps are drawn from the
/// row's layout off the main thread. Mounted rows are recycled; nothing here
/// lays text out.
nonisolated final class RowLayer: CALayer {
    /// Bounded 2D tile dimensions: normal rows (<= 760 pt) stay 1 column wide
    /// (zero extra tiles), while wide code/table blocks tile horizontally so
    /// every `IOSurface` stays <= 6 MB @ 2x / <= 13.5 MB @ 3x and well below
    /// Metal's 16,384 px texture limit.
    static let bandWidth: CGFloat = 768
    static let bandHeight: CGFloat = 512

    /// The frames of a row's tiles covering `bounds` (in row coordinates,
    /// row-major): none when `bounds` is empty, so non-painting rows hold no
    /// `IOSurface`.
    static func bandFrames(in bounds: CGRect) -> [CGRect] {
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return [] }
        let rows = Int(ceil(bounds.height / bandHeight))
        let cols = Int(ceil(bounds.width / bandWidth))
        var frames: [CGRect] = []
        frames.reserveCapacity(rows * cols)
        for row in 0..<rows {
            let top = bounds.minY + CGFloat(row) * bandHeight
            let h = min(bandHeight, bounds.maxY - top)
            for col in 0..<cols {
                let left = bounds.minX + CGFloat(col) * bandWidth
                frames.append(CGRect(x: left, y: top, width: min(bandWidth, bounds.maxX - left), height: h))
            }
        }
        return frames
    }

    private struct TileKey: Hashable {
        let col: Int
        let row: Int
    }

    private(set) var rowID: String?
    private(set) var layoutKey: RowLayoutKey?
    private(set) var content: RowContentLayout = .empty
    /// A code block or table wider than its row draws its body in a
    /// horizontal scroller instead of here.
    private(set) var drawsWideBody = true
    /// Normal single-column rows keep their few band sublayers attached in a
    /// flat array (zero dict hashing or CA add/removeSublayer churn on scroll
    /// and reuse). Multi-column wide blocks or very tall surfaces switch to
    /// sparse on-demand 2D tiles so arbitrarily wide blocks never allocate
    /// thousands of off-screen sublayers.
    private var linearBands: [RowBandLayer] = []
    private var isSparseGrid = false
    private var tiles: [TileKey: RowBandLayer] = [:]
    private var tilePool: [RowBandLayer] = []
    private var paintedRect: CGRect = .zero
    private var colCount = 0
    private var rowCount = 0
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
            bounds: layout.content.paintedBounds(
                drawsWideBody: drawsWideBody, rowWidth: bounds.width, rowHeight: layout.height),
            scale: scale, unchangedHeight: unchanged, drawn: bitmaps)
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

    /// Draws the tiles crossing `rect` (row coordinates) that do not show
    /// their current bitmap (`REDESIGN.md §7 R3`): visible non-current bands
    /// draw synchronously in the frame so scrubbing and live resize show zero
    /// blanks or stale widths; off-screen prefetch bands draw asynchronously on
    /// `RasterQueue` when `offMain` is true.
    @MainActor
    func drawBands(in rect: CGRect, visible: CGRect, offMain: Bool) {
        guard let palette, colCount > 0, rowCount > 0, !rect.isNull, !rect.isEmpty else { return }
        let drawsNow = !offMain
        if !isSparseGrid {
            for band in linearBands where !band.isCurrent && band.frame.intersects(rect) {
                submitBand(band, palette: palette, visible: visible, drawsNow: drawsNow, is2D: false)
            }
            return
        }
        let minCol = max(0, Int(floor((rect.minX - paintedRect.minX) / Self.bandWidth)))
        let maxCol = min(colCount - 1, Int(floor((rect.maxX - paintedRect.minX - 0.001) / Self.bandWidth)))
        let minRow = max(0, Int(floor((rect.minY - paintedRect.minY) / Self.bandHeight)))
        let maxRow = min(rowCount - 1, Int(floor((rect.maxY - paintedRect.minY - 0.001) / Self.bandHeight)))
        guard minCol <= maxCol, minRow <= maxRow else { return }
        for row in minRow...maxRow {
            for col in minCol...maxCol {
                let frame = tileFrame(col: col, row: row)
                guard frame.intersects(rect) else { continue }
                let band = acquireTile(for: TileKey(col: col, row: row), frame: frame, scale: contentsScale)
                submitBand(band, palette: palette, visible: visible, drawsNow: drawsNow, is2D: true)
            }
        }
    }

    @MainActor
    private func submitBand(
        _ band: RowBandLayer, palette: TextPalette, visible: CGRect, drawsNow: Bool, is2D: Bool
    ) {
        guard !band.isCurrent else { return }
        let syncForVisible = !drawsNow && !visible.isNull && band.frame.intersects(visible)
        guard drawsNow || syncForVisible || !band.isPending else { return }
        let raster = BandRaster(
            content: content, palette: palette, drawsWideBody: drawsWideBody, rect: band.frame,
            scale: contentsScale, colorSpace: bandColorSpace ?? Self.colorSpace)
        if drawsNow || syncForVisible {
            band.show(BandRasterizer.bitmap(raster), generation: band.generation)
            return
        }
        let distance: CGFloat
        if visible.isNull {
            distance = 0
        } else {
            let dy = max(0, band.frame.minY - visible.maxY, visible.minY - band.frame.maxY)
            let dx = is2D ? max(0, band.frame.minX - visible.maxX, visible.minX - band.frame.maxX) : 0
            distance = dx + dy
        }
        RasterQueue.shared.submit(band, raster: raster, priority: distance)
    }

    /// Releases bitmaps of bands far from `rect` (row coordinates), and
    /// recycles sublayers for sparse 2D wide-block grids.
    @MainActor
    func releaseBands(outside rect: CGRect) {
        if !isSparseGrid {
            for band in linearBands where (band.contents != nil || band.isPending) && !band.frame.intersects(rect) {
                band.release()
            }
            return
        }
        var toRecycle: [(TileKey, RowBandLayer)] = []
        for (key, band) in tiles where !band.frame.intersects(rect) {
            toRecycle.append((key, band))
        }
        for (key, band) in toRecycle { recycleTile(key, band) }
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
        paintedRect = .zero
        colCount = 0
        rowCount = 0
        for band in linearBands { band.release() }
        if !tiles.isEmpty {
            let oldTiles = Array(tiles)
            for (key, band) in oldTiles { recycleTile(key, band) }
        }
        isSparseGrid = false
        shape.isHidden = true
        masksToBounds = false
    }

    private func tileFrame(col: Int, row: Int) -> CGRect {
        let left = paintedRect.minX + CGFloat(col) * Self.bandWidth
        let top = paintedRect.minY + CGFloat(row) * Self.bandHeight
        return CGRect(
            x: left, y: top,
            width: min(Self.bandWidth, paintedRect.maxX - left),
            height: min(Self.bandHeight, paintedRect.maxY - top))
    }

    @MainActor
    private func acquireTile(for key: TileKey, frame: CGRect, scale: CGFloat) -> RowBandLayer {
        if let existing = tiles[key] { return existing }
        let band = tilePool.popLast() ?? RowBandLayer()
        band.frame = frame
        band.contentsScale = scale
        band.invalidate()
        tiles[key] = band
        addSublayer(band)
        return band
    }

    @MainActor
    private func recycleTile(_ key: TileKey, _ band: RowBandLayer) {
        tiles[key] = nil
        band.release()
        band.removeFromSuperlayer()
        if tilePool.count < 16 { tilePool.append(band) }
    }

    @MainActor
    private func configureBands(
        bounds: CGRect, scale: CGFloat, unchangedHeight: CGFloat,
        drawn: [(frame: CGRect, bitmap: BandBitmap?)]
    ) {
        if !bounds.isNull, bounds.width > 0, bounds.height > 0 {
            paintedRect = bounds
            rowCount = Int(ceil(bounds.height / Self.bandHeight))
            colCount = Int(ceil(bounds.width / Self.bandWidth))
        } else {
            paintedRect = .zero
            rowCount = 0
            colCount = 0
        }
        let useSparse = colCount > 1 || rowCount > 16
        if useSparse != isSparseGrid {
            if useSparse {
                while let band = linearBands.popLast() {
                    band.release()
                    band.removeFromSuperlayer()
                    if tilePool.count < 16 { tilePool.append(band) }
                }
            } else if !tiles.isEmpty {
                let oldTiles = Array(tiles)
                for (key, band) in oldTiles { recycleTile(key, band) }
            }
            isSparseGrid = useSparse
        }

        if !useSparse {
            let count = rowCount
            while linearBands.count < count {
                let band = tilePool.popLast() ?? RowBandLayer()
                linearBands.append(band)
                addSublayer(band)
            }
            while linearBands.count > count {
                let band = linearBands.removeLast()
                band.release()
                band.removeFromSuperlayer()
                if tilePool.count < 16 { tilePool.append(band) }
            }
            for row in 0..<count {
                updateBand(
                    linearBands[row], frame: tileFrame(col: 0, row: row), scale: scale,
                    unchangedHeight: unchangedHeight, drawn: drawn, requiresExactWidth: false)
            }
            return
        }

        var staleTiles: [(TileKey, RowBandLayer)] = []
        for (key, band) in tiles {
            guard key.row < rowCount, key.col < colCount else {
                staleTiles.append((key, band))
                continue
            }
            updateBand(
                band, frame: tileFrame(col: key.col, row: key.row), scale: scale,
                unchangedHeight: unchangedHeight, drawn: drawn, requiresExactWidth: true)
        }
        for (key, band) in staleTiles { recycleTile(key, band) }
        // Mount pre-drawn bands (streamed tail updates) immediately so new
        // size and new pixels land in the same transaction.
        for item in drawn {
            guard let bitmap = item.bitmap else { continue }
            let col = Int(((item.frame.minX - paintedRect.minX) / Self.bandWidth).rounded())
            let row = Int(((item.frame.minY - paintedRect.minY) / Self.bandHeight).rounded())
            guard col >= 0, col < colCount, row >= 0, row < rowCount else { continue }
            let expected = tileFrame(col: col, row: row)
            guard expected == item.frame else { continue }
            let key = TileKey(col: col, row: row)
            if tiles[key] == nil {
                let band = acquireTile(for: key, frame: expected, scale: scale)
                band.show(bitmap, generation: band.generation)
            }
        }
    }

    @MainActor
    private func updateBand(
        _ band: RowBandLayer, frame: CGRect, scale: CGFloat, unchangedHeight: CGFloat,
        drawn: [(frame: CGRect, bitmap: BandBitmap?)], requiresExactWidth: Bool
    ) {
        if let bitmap = drawn.first(where: { $0.frame == frame })?.bitmap {
            band.frame = frame
            band.contentsScale = scale
            band.invalidate()
            band.show(bitmap, generation: band.generation)
            return
        }
        let widthMatches = !requiresExactWidth || band.frame.width == frame.width
        if band.isCurrent || band.isPending, band.frame.origin == frame.origin,
            band.frame.height == frame.height, widthMatches, frame.maxY <= unchangedHeight
        {
            if band.frame.width != frame.width { band.frame = frame }
            return
        }
        if band.frame != frame { band.frame = frame }
        band.contentsScale = scale
        band.invalidate()
    }

    private func configureShape(palette: TextPalette) {
        switch content {
        case .bubble(_, let frame, _):
            shape.isHidden = false
            shape.frame = frame
            shape.backgroundColor = palette.bubble
            shape.cornerRadius = TextStyle.bubbleCornerRadius
            shape.maskedCorners = Self.allCorners
            shape.borderWidth = 0
            masksToBounds = false
        case .code(_, let frame):
            shape.isHidden = false
            shape.frame = frame
            shape.backgroundColor = palette.codeBackground
            shape.cornerRadius = TextStyle.codeCornerRadius
            shape.maskedCorners = Self.allCorners
            shape.borderWidth = 1
            shape.borderColor = palette.codeBorder
            masksToBounds = false
        case .notice(_, let frame, _):
            shape.isHidden = false
            shape.frame = frame
            shape.backgroundColor = palette.warning
            shape.cornerRadius = TextStyle.noticeCornerRadius
            shape.maskedCorners = Self.allCorners
            shape.borderWidth = 0
            masksToBounds = false
        default:
            shape.isHidden = true
            masksToBounds = false
        }
    }

    private static let allCorners: CACornerMask = [
        .layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
    ]
}
