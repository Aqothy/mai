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

    /// The frames of a row's tiles, in row coordinates (row-major): none for a
    /// row that paints nothing, so it holds no `IOSurface`.
    static func bandFrames(height: CGFloat, width: CGFloat) -> [CGRect] {
        guard height > 0, width > 0 else { return [] }
        let rows = Int(ceil(height / bandHeight))
        let cols = Int(ceil(width / bandWidth))
        var frames: [CGRect] = []
        frames.reserveCapacity(rows * cols)
        for row in 0..<rows {
            let top = CGFloat(row) * bandHeight
            let h = min(bandHeight, height - top)
            for col in 0..<cols {
                let left = CGFloat(col) * bandWidth
                frames.append(CGRect(x: left, y: top, width: min(bandWidth, width - left), height: h))
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
    private var paintedWidth: CGFloat = 0
    private var paintedHeight: CGFloat = 0
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

    /// Draws the tiles crossing `rect` (row coordinates) that do not show
    /// their current bitmap: always off the main thread when `offMain` is on,
    /// nearest to `visible` first, each keeping what it shows until its new
    /// bitmap lands. Only `!offMain` (debug benchmark flag) draws
    /// synchronously. Returns how many were drawn now.
    @MainActor
    @discardableResult
    func drawBands(in rect: CGRect, visible: CGRect, offMain: Bool) -> Int {
        guard let palette, colCount > 0, rowCount > 0, !rect.isNull, !rect.isEmpty else { return 0 }
        let drawsNow = !offMain
        var drawnNow = 0
        if !isSparseGrid {
            for band in linearBands where !band.isCurrent && band.frame.intersects(rect) {
                drawnNow += submitBand(band, palette: palette, visible: visible, drawsNow: drawsNow, is2D: false)
            }
            return drawnNow
        }
        let minCol = max(0, Int(floor(rect.minX / Self.bandWidth)))
        let maxCol = min(colCount - 1, Int(floor((rect.maxX - 0.001) / Self.bandWidth)))
        let minRow = max(0, Int(floor(rect.minY / Self.bandHeight)))
        let maxRow = min(rowCount - 1, Int(floor((rect.maxY - 0.001) / Self.bandHeight)))
        guard minCol <= maxCol, minRow <= maxRow else { return 0 }
        for row in minRow...maxRow {
            for col in minCol...maxCol {
                let frame = tileFrame(col: col, row: row)
                guard frame.intersects(rect) else { continue }
                let band = acquireTile(for: TileKey(col: col, row: row), frame: frame, scale: contentsScale)
                drawnNow += submitBand(band, palette: palette, visible: visible, drawsNow: drawsNow, is2D: true)
            }
        }
        return drawnNow
    }

    @MainActor
    private func submitBand(
        _ band: RowBandLayer, palette: TextPalette, visible: CGRect, drawsNow: Bool, is2D: Bool
    ) -> Int {
        guard !band.isCurrent, drawsNow || !band.isPending else { return 0 }
        let raster = BandRaster(
            content: content, palette: palette, drawsWideBody: drawsWideBody, rect: band.frame,
            scale: contentsScale, colorSpace: bandColorSpace ?? Self.colorSpace)
        if drawsNow {
            band.show(BandRasterizer.bitmap(raster), generation: band.generation)
            return 1
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
        return 0
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
        paintedWidth = 0
        paintedHeight = 0
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
        let left = CGFloat(col) * Self.bandWidth
        let top = CGFloat(row) * Self.bandHeight
        return CGRect(
            x: left, y: top,
            width: min(Self.bandWidth, paintedWidth - left),
            height: min(Self.bandHeight, paintedHeight - top))
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
        height: CGFloat, width: CGFloat, scale: CGFloat, unchangedHeight: CGFloat,
        drawn: [(frame: CGRect, bitmap: BandBitmap?)]
    ) {
        paintedHeight = max(0, height)
        paintedWidth = max(0, width)
        if paintedHeight > 0 && paintedWidth > 0 {
            rowCount = Int(ceil(paintedHeight / Self.bandHeight))
            colCount = Int(ceil(paintedWidth / Self.bandWidth))
        } else {
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
            let col = Int((item.frame.minX / Self.bandWidth).rounded())
            let row = Int((item.frame.minY / Self.bandHeight).rounded())
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
        case .bubble(_, let frame, _, let position):
            shape.isHidden = false
            shape.frame = frame
            shape.backgroundColor = palette.bubble
            shape.cornerRadius = TextStyle.bubbleCornerRadius
            shape.maskedCorners = Self.maskedCorners(for: position)
            shape.borderWidth = 0
            masksToBounds = false
        case .code(let code, let frame):
            shape.isHidden = false
            // Bleed 1 pt past joined edges and clip at the row bounds so
            // adjacent chunks of a split code block share a seamless border.
            let joinTop: CGFloat = code.position.joinsAbove ? 1 : 0
            let joinBottom: CGFloat = code.position.joinsBelow ? 1 : 0
            shape.frame = CGRect(
                x: frame.minX, y: frame.minY - joinTop,
                width: frame.width, height: frame.height + joinTop + joinBottom)
            shape.backgroundColor = palette.codeBackground
            shape.cornerRadius = TextStyle.codeCornerRadius
            shape.maskedCorners = Self.maskedCorners(for: code.position)
            shape.borderWidth = 1
            shape.borderColor = palette.codeBorder
            masksToBounds = code.position.joinsAbove || code.position.joinsBelow
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

    private static func maskedCorners(for position: TranscriptBlockPosition) -> CACornerMask {
        if !position.joinsAbove && !position.joinsBelow { return allCorners }
        // Both iOS and macOS (`rowsView.rowsLayer.isGeometryFlipped = true`)
        // lay rows out top-down so `minY` is the visual top edge.
        let top: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        let bottom: CACornerMask = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        var mask: CACornerMask = []
        if !position.joinsAbove { mask.formUnion(top) }
        if !position.joinsBelow { mask.formUnion(bottom) }
        return mask
    }
}
