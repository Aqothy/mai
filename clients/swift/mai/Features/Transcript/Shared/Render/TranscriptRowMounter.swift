import QuartzCore

/// What a platform document does for the mounter beyond layers: a code
/// block or table wider than its row scrolls horizontally in a native scroll
/// view (PLAN 3.9), and rows have native controls, which only the platform
/// can make.
@MainActor
protocol TranscriptRowMounterDelegate: AnyObject {
    /// Shows `body` in a horizontal scroller, the row's top left at `origin`
    /// (document coordinates). `drawn` and `visible` are in document
    /// coordinates so tall wide blocks vertically clip and release bands just
    /// like normal rows. `streamed` carries bands pre-drawn with a streamed
    /// layout so wide blocks update size and pixels in the same frame.
    func showWideBlock(
        rowID: String, body: WideBlockBody, key: RowLayoutKey, origin: CGPoint, drawn: CGRect,
        visible: CGRect, streamed: DrawnBands?)
    func removeWideBlock(rowID: String)
    /// Highlights `range` of a wide block's text in its scroller.
    func showWideBlockSelection(rowID: String, range: Range<Int>?, color: CGColor)
    /// Shows a row's native controls; `origin` is the row's top left in
    /// the document. Called on every placement of the row; cheap when
    /// nothing changed.
    func showAccessories(rowID: String, accessories: [RowAccessory], origin: CGPoint)
    func removeAccessories(rowID: String)
}

/// Keeps a layer per row near the viewport, for both platforms' documents
/// (PLAN 4.3, 4.4). Layouts and band bitmaps run strictly off the main thread
/// (pure async + blanking); rows up to 1.5 screens ahead and half a screen
/// behind are drawn ahead of the scroll; drawn rows within one more screen are
/// kept, the rest go back to the pool.
///
/// Rows sit in document coordinates, so scrolling alone moves nothing here:
/// placement runs only when the controller changed rows, heights or
/// layouts (`invalidate()`), or the viewport left the span placed for it or
/// moved an eighth of a screen (to keep drawing ahead).
@MainActor
final class TranscriptRowMounter {
    let container: CALayer
    weak var delegate: (any TranscriptRowMounterDelegate)?
    /// Bands draw on background tasks (off only to compare, DEBUG
    /// `-ChatTranscriptRaster main`).
    var drawsOffMain = true
    private var mounted: [String: RowLayer] = [:]
    /// Whether any row may show a highlight, so rows without a selection
    /// skip the lookup.
    private var hasSelection = false
    private var pool: [RowLayer] = []
    private var stamp = 0
    private var isStale = true
    private var placedTop: CGFloat = 0
    private var lastTop: CGFloat = 0
    /// The rows drawn at the last placement, and the span around the
    /// viewport whose rows were all mounted then.
    private var placedDrawn: CGRect = .null
    private var placedWidth: CGFloat = 0
    private var readySpan: ClosedRange<CGFloat>?
    /// The region the platform asked to have ready (Mac `prepareContent(in:)`).
    private var preparedRect: CGRect = .null
    /// The selection highlight's color; the host sets it as the window's key
    /// state changes.
    var selectionColor: CGColor = CGColor(gray: 0.5, alpha: 0.3)
    /// Off where the platform draws the highlight itself (UIKit's text
    /// interaction on iOS).
    var drawsSelection = true

    init(container: CALayer) {
        self.container = container
    }

    var mountedRowCount: Int { mounted.count }

    /// Rows, heights or layouts changed: place again before the next frame.
    func invalidate() {
        isStale = true
    }

    /// The platform wants `rect` (document coordinates) ready to scroll into.
    func prepare(_ rect: CGRect) {
        preparedRect = rect
    }

    /// Releases off-screen bitmaps and clears the layer pool (iOS memory
    /// warning / backgrounding, PLAN 4.4).
    func releaseOffscreen(keeping visible: CGRect) {
        for (id, layer) in mounted {
            if !layer.placedFrame.intersects(visible) {
                unmount(id, layer)
            } else {
                let local = visible.offsetBy(dx: -layer.placedFrame.minX, dy: -layer.placedFrame.minY)
                layer.releaseBands(outside: local)
            }
        }
        pool.removeAll()
        isStale = true
    }

    /// Whether `visible` needs a placement before it can be shown.
    func needsPlacement(visible: CGRect) -> Bool {
        // A new width re-centers the column.
        if isStale || visible.width != placedWidth { return true }
        guard let readySpan, readySpan.contains(visible.minY), readySpan.contains(visible.maxY) else { return true }
        let step = max(1, visible.height) / 8
        if abs(visible.minY - placedTop) > step { return true }
        if !preparedRect.isNull {
            let coveredMinY = placedDrawn.minY - step
            let coveredMaxY = placedDrawn.maxY + step
            if preparedRect.minY < coveredMinY || preparedRect.maxY > coveredMaxY { return true }
        }
        return false
    }

    /// Mounts, positions and draws the rows for `visible` (document
    /// coordinates) in a column of `documentWidth`. `showsContent` is false
    /// while the transcript waits for its first rows (PLAN 3.9 rule 9).
    func place(
        _ controller: TranscriptController, visible: CGRect, documentWidth: CGFloat, palette: TextPalette,
        scale: CGFloat, colorSpace: CGColorSpace? = nil, showsContent: Bool
    ) {
        let space = colorSpace ?? RowLayer.colorSpace
        hasSelection = drawsSelection && controller.selection != nil
        isStale = false
        let geometry = controller.geometry
        let screen = max(1, visible.height)
        let downward: Bool
        if abs(visible.minY - lastTop) > 4 {
            downward = visible.minY > lastTop
        } else {
            downward = controller.isScrollingDown
        }
        lastTop = visible.minY
        placedTop = visible.minY
        var drawn = CGRect(
            x: 0, y: visible.minY - (downward ? 0.5 : 1.5) * screen, width: documentWidth,
            height: visible.height + 2 * screen)
        if !preparedRect.isNull, preparedRect.height > 0 { drawn = drawn.union(preparedRect) }
        placedDrawn = drawn
        placedWidth = visible.width
        let kept = drawn.insetBy(dx: 0, dy: -screen)
        stamp &+= 1

        // The span around the viewport whose rows are all mounted: bounded by
        // the nearest row above and below the viewport still waiting for its
        // layout.
        var spanTop = drawn.minY
        var spanBottom = drawn.maxY
        var missingLayouts: [Int] = []
        #if DEBUG
            var staleVisibleRows = 0
            var visibleWidthLag: CGFloat = 0
        #endif
        if let range = geometry.indices(overlapping: max(0, drawn.minY), drawn.maxY) {
            for rowIndex in range {
                let (minY, height) = geometry.frame(at: rowIndex)
                let frame = CGRect(x: 0, y: minY, width: documentWidth, height: height)
                guard let layout = controller.layout(forRowAt: rowIndex) else {
                    missingLayouts.append(rowIndex)
                    if frame.maxY <= visible.minY {
                        spanTop = max(spanTop, frame.maxY)
                    } else if frame.minY >= visible.maxY {
                        spanBottom = min(spanBottom, frame.minY)
                    } else {
                        // A visible row without a layout yet (pure async +
                        // blanking): keep placement armed until it lands.
                        spanTop = visible.midY
                        spanBottom = visible.midY
                    }
                    continue
                }
                #if DEBUG
                    if layout.key.width != controller.columnWidth, frame.intersects(visible) {
                        staleVisibleRows += 1
                        visibleWidthLag = max(visibleWidthLag, abs(layout.key.width - controller.columnWidth))
                    }
                    if layout.height != frame.height, frame.intersects(visible) {
                        TranscriptDebugCounters.misplacedRows += 1
                    }
                #endif
                mount(
                    controller.rows[rowIndex], index: rowIndex, frame: frame, layout: layout, controller: controller,
                    documentWidth: documentWidth, visible: visible, drawn: drawn, palette: palette, scale: scale,
                    colorSpace: space, showsContent: showsContent)
            }
        }
        readySpan = spanTop <= spanBottom ? spanTop...spanBottom : nil
        #if DEBUG
            TranscriptDebugCounters.staleVisibleRows = staleVisibleRows
            TranscriptDebugCounters.visibleWidthLag = visibleWidthLag
        #endif
        if !missingLayouts.isEmpty { controller.prefetch(missingLayouts) }

        for (id, layer) in mounted where layer.placementStamp != stamp {
            if let index = geometry.index(for: id), controller.rows[index].id == id {
                let (minY, height) = geometry.frame(at: index)
                let frame = CGRect(x: 0, y: minY, width: documentWidth, height: height)
                if frame.minY < kept.maxY, frame.maxY > kept.minY {
                    // Near enough to keep: its bitmap saves a redraw if the
                    // reader turns back; only its position follows geometry.
                    if layer.placedFrame.minY != frame.minY {
                        layer.placedFrame.origin.y = frame.minY
                        layer.frame = layer.placedFrame
                        let origin = layer.placedFrame.origin
                        if layer.hasAccessories, let layout = controller.layouts[id] {
                            layer.accessoriesOrigin = origin
                            delegate?.showAccessories(
                                rowID: id, accessories: layout.content.accessories(), origin: origin)
                        }
                        if layer.hasWideBlock, let layout = controller.layouts[id],
                            let wideBody = layout.content.wideBody
                        {
                            delegate?.showWideBlock(
                                rowID: id, body: wideBody,
                                key: layout.key, origin: origin, drawn: drawn, visible: visible, streamed: nil)
                        }
                    }
                    continue
                }
            }
            unmount(id, layer)
        }
        controller.preDrawnBands.removeAll()
    }

    /// Redraws the selection highlight on every mounted row, and the code
    /// scrollers' through the delegate.
    func showSelection(_ controller: TranscriptController) {
        guard drawsSelection, hasSelection || controller.selection != nil else { return }
        hasSelection = controller.selection != nil
        let fullWidth = controller.selection?.isSelectAll == true
        let geometry = controller.geometry
        for (id, layer) in mounted {
            guard let index = geometry.index(for: id), controller.rows[index].id == id else { continue }
            let range = controller.selectedRange(inRowAt: index)
            layer.showSelection(range, color: selectionColor, fullWidth: fullWidth)
            if layer.hasWideBlock { delegate?.showWideBlockSelection(rowID: id, range: range, color: selectionColor) }
        }
    }

    private func mount(
        _ row: TranscriptRow, index: Int, frame: CGRect, layout: RowLayout, controller: TranscriptController,
        documentWidth: CGFloat, visible: CGRect, drawn: CGRect, palette: TextPalette, scale: CGFloat,
        colorSpace: CGColorSpace, showsContent: Bool
    ) {
        let width = layout.key.width
        let x = max(0, ((documentWidth - width) / 2).rounded(.down))
        let layer: RowLayer
        if let existing = mounted[row.id] {
            layer = existing
        } else {
            layer = pool.popLast() ?? RowLayer()
            container.addSublayer(layer)
            mounted[row.id] = layer
        }
        layer.placementStamp = stamp
        let target = CGRect(x: x, y: frame.minY, width: width, height: frame.height)
        if layer.placedFrame != target {
            layer.placedFrame = target
            layer.frame = target
        }
        let wideBody = layout.content.wideBody
        // Bands pre-drawn with a streamed or cold layout, if this is the layout
        // shown (not one that replaced it since, such as its colors).
        let preDrawn = controller.preDrawnBands[row.id].flatMap { entry in
            entry.layout.key == layout.key && entry.layout.content.isHighlighted == layout.content.isHighlighted
                ? entry.drawn : nil
        }
        layer.show(
            rowID: row.id, layout: layout, palette: palette, drawsWideBody: wideBody == nil, scale: scale,
            colorSpace: colorSpace, drawn: preDrawn)
        layer.showSelection(
            hasSelection ? controller.selectedRange(inRowAt: index) : nil, color: selectionColor,
            fullWidth: controller.selection?.isSelectAll == true)
        let local = drawn.offsetBy(dx: -x, dy: -frame.minY)
        let localVisible = showsContent ? visible.offsetBy(dx: -x, dy: -frame.minY) : .null
        layer.drawBands(in: local, visible: localVisible, offMain: drawsOffMain)
        layer.releaseBands(outside: local.insetBy(dx: 0, dy: -visible.height))
        // Accessories follow the layout and the row's place only: a table's
        // copy text joins all its cells, so it is not made on every pass.
        let origin = CGPoint(x: x, y: frame.minY)
        if layer.accessoriesKey != layout.key || layer.accessoriesOrigin != origin {
            layer.accessoriesKey = layout.key
            layer.accessoriesOrigin = origin
            let accessories = layout.content.accessories()
            if !accessories.isEmpty {
                layer.hasAccessories = true
                delegate?.showAccessories(rowID: row.id, accessories: accessories, origin: origin)
            } else if layer.hasAccessories {
                layer.hasAccessories = false
                delegate?.removeAccessories(rowID: row.id)
            }
        }
        if let wideBody {
            layer.hasWideBlock = true
            delegate?.showWideBlock(
                rowID: row.id, body: wideBody, key: layout.key,
                origin: origin, drawn: drawn, visible: showsContent ? visible : .null,
                streamed: preDrawn?.wideBodyDrawn)
            delegate?.showWideBlockSelection(
                rowID: row.id, range: hasSelection ? controller.selectedRange(inRowAt: index) : nil,
                color: selectionColor)
        } else if layer.hasWideBlock {
            layer.hasWideBlock = false
            delegate?.removeWideBlock(rowID: row.id)
        }
    }

    private func unmount(_ id: String, _ layer: RowLayer) {
        mounted[id] = nil
        if layer.hasWideBlock { delegate?.removeWideBlock(rowID: id) }
        if layer.hasAccessories { delegate?.removeAccessories(rowID: id) }
        layer.removeFromSuperlayer()
        layer.resetForReuse()
        if pool.count < 48 { pool.append(layer) }
    }
}
