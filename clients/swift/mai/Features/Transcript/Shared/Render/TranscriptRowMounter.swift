import QuartzCore

/// What a platform document does for the mounter beyond layers: a code
/// block or table wider than its row scrolls horizontally in a native scroll
/// view (PLAN 3.9), and rows have native controls, which only the platform
/// can make.
@MainActor
protocol TranscriptRowMounterDelegate: AnyObject {
    /// Shows `body` in a horizontal scroller, the row's top left at `origin`
    /// (document coordinates). Called on every placement of the row; cheap
    /// when nothing changed.
    func showWideBlock(rowID: String, body: WideBlockBody, key: RowLayoutKey, origin: CGPoint, isVisible: Bool)
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
/// (PLAN 4.3, 4.4). Visible rows always have a layout (laid out now when
/// missing, D3); rows up to 1.5 screens ahead and half a screen behind are
/// drawn ahead of the scroll; drawn rows within one more screen are kept,
/// the rest go back to the pool.
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
    /// Read once per placement: streamed text fades in unless motion is
    /// reduced.
    private var reducesMotion = false
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

    /// Whether `visible` needs a placement before it can be shown.
    func needsPlacement(visible: CGRect) -> Bool {
        // A new width re-centers the column.
        if isStale || visible.width != placedWidth { return true }
        guard let readySpan, readySpan.contains(visible.minY), readySpan.contains(visible.maxY) else { return true }
        let step = max(1, visible.height) / 8
        if abs(visible.minY - placedTop) > step { return true }
        return !preparedRect.isNull && !placedDrawn.insetBy(dx: 0, dy: -step).contains(preparedRect)
    }

    /// Mounts, positions and draws the rows for `visible` (document
    /// coordinates) in a column of `documentWidth`. `showsContent` is false
    /// while the transcript waits for its first rows (PLAN 3.9 rule 9): no
    /// synchronous layouts then.
    func place(
        _ controller: TranscriptController, visible: CGRect, documentWidth: CGFloat, palette: TextPalette,
        scale: CGFloat, showsContent: Bool
    ) {
        reducesMotion = TranscriptMotion.isReduced
        hasSelection = drawsSelection && controller.selection != nil
        isStale = false
        let geometry = controller.geometry
        let screen = max(1, visible.height)
        let downward = visible.minY >= lastTop
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
        if let range = geometry.indices(overlapping: max(0, drawn.minY), drawn.maxY) {
            for index in range {
                let (minY, height) = geometry.frame(at: index)
                let frame = CGRect(x: 0, y: minY, width: documentWidth, height: height)
                guard let layout = controller.layout(forRowAt: index, synchronously: false) else {
                    missingLayouts.append(index)
                    if frame.maxY <= visible.minY {
                        spanTop = max(spanTop, frame.maxY)
                    } else if frame.minY >= visible.maxY {
                        spanBottom = min(spanBottom, frame.minY)
                    } else {
                        // A visible row without a layout: only while hidden.
                        spanTop = visible.midY
                        spanBottom = visible.midY
                    }
                    continue
                }
                mount(
                    controller.rows[index], index: index, frame: frame, layout: layout, controller: controller,
                    documentWidth: documentWidth, visible: visible, drawn: drawn, palette: palette, scale: scale,
                    showsContent: showsContent)
            }
        }
        readySpan = spanTop <= spanBottom ? spanTop...spanBottom : nil
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
                    }
                    continue
                }
            }
            unmount(id, layer)
        }
        // Arrived rows are mounted now; later mounts are misses again.
        controller.arrivedRowIDs.removeAll()
    }

    /// Redraws the selection highlight on every mounted row, and the code
    /// scrollers' through the delegate.
    func showSelection(_ controller: TranscriptController) {
        guard drawsSelection, hasSelection || controller.selection != nil else { return }
        hasSelection = controller.selection != nil
        let geometry = controller.geometry
        for (id, layer) in mounted {
            guard let index = geometry.index(for: id), controller.rows[index].id == id else { continue }
            let range = controller.selectedRange(inRowAt: index)
            layer.showSelection(range, color: selectionColor)
            if layer.hasWideBlock { delegate?.showWideBlockSelection(rowID: id, range: range, color: selectionColor) }
        }
    }

    private func mount(
        _ row: TranscriptRow, index: Int, frame: CGRect, layout: RowLayout, controller: TranscriptController,
        documentWidth: CGFloat, visible: CGRect, drawn: CGRect, palette: TextPalette, scale: CGFloat,
        showsContent: Bool
    ) {
        let width = layout.key.width
        let x = max(0, ((documentWidth - width) / 2).rounded(.down))
        let layer: RowLayer
        let isNew: Bool
        if let existing = mounted[row.id] {
            layer = existing
            isNew = false
        } else {
            layer = pool.popLast() ?? RowLayer()
            container.addSublayer(layer)
            mounted[row.id] = layer
            isNew = true
        }
        layer.placementStamp = stamp
        let target = CGRect(x: x, y: frame.minY, width: width, height: max(frame.height, layout.height))
        if layer.placedFrame != target {
            layer.placedFrame = target
            layer.frame = target
        }
        let wideBody = layout.content.wideBody
        let isStreaming = controller.isStreaming(row)
        layer.show(
            rowID: row.id, layout: layout, palette: palette, drawsWideBody: wideBody == nil, scale: scale,
            isGrowing: isStreaming, fadesNewText: isStreaming && !reducesMotion,
            isArrival: controller.arrivedRowIDs.contains(row.id))
        if hasSelection {
            layer.showSelection(controller.selectedRange(inRowAt: index), color: selectionColor)
        }
        let local = drawn.offsetBy(dx: -x, dy: -frame.minY)
        let localVisible = visible.offsetBy(dx: -x, dy: -frame.minY)
        let drawnNow = layer.drawBands(in: local, visible: localVisible, offMain: drawsOffMain)
        layer.releaseBands(outside: local.insetBy(dx: 0, dy: -visible.height))
        #if DEBUG
            // Bands drawn on the main thread because they reached the screen
            // with nothing to show: rows streamed in arrive that way; others
            // were not drawn ahead (PLAN D3).
            if drawnNow > 0, showsContent, drawsOffMain {
                if controller.arrivedRowIDs.contains(row.id) {
                    TranscriptDebugCounters.arrivalDraws += drawnNow
                } else {
                    TranscriptDebugCounters.syncFallbackDraws += drawnNow
                }
            }
        #else
            _ = (isNew, drawnNow, showsContent)
        #endif
        // Accessories follow the layout and the row's place only: a table's
        // copy text joins all its cells, so it is not made on every pass.
        let origin = CGPoint(x: x, y: frame.minY)
        if layer.accessoriesKey != layout.key || layer.accessoriesOrigin != origin {
            layer.accessoriesKey = layout.key
            layer.accessoriesOrigin = origin
            let accessories = layout.content.accessories
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
                rowID: row.id, body: wideBody, key: layout.key, origin: CGPoint(x: x, y: frame.minY),
                isVisible: target.intersects(visible))
            if hasSelection {
                delegate?.showWideBlockSelection(
                    rowID: row.id, range: controller.selectedRange(inRowAt: index), color: selectionColor)
            }
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
