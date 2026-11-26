#if os(macOS)
    import AppKit

    /// A wide block's body (code lines or a table's grid) inside its
    /// horizontal scroller.
    final class TranscriptWideBlockBodyView: NSView {
        private let row = RowLayer()

        // Constant, so AppKit's frequent calls skip the main-actor check.
        nonisolated override var isFlipped: Bool { true }

        /// Layer-hosting, like the transcript's rows view: the row layer is
        /// ours to manage.
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let host = CALayer()
            host.isGeometryFlipped = true
            host.addSublayer(row)
            layer = host
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private var lastDrawnY: CGRect = .null
        private var lastVisibleY: CGRect = .null
        private var lastContentWidth: CGFloat = 0
        private var lastDrawsOffMain = true
        private var lastHorizontalDrawnX: CGFloat = .nan
        private var lastHorizontalDrawnSpan: ClosedRange<CGFloat>?

        func show(
            rowID: String, body: WideBlockBody, key: RowLayoutKey, palette: TextPalette, scale: CGFloat,
            colorSpace: CGColorSpace, drawsOffMain: Bool, drawn: CGRect, visible: CGRect,
            horizontalVisible: ClosedRange<CGFloat>, streamed: DrawnBands?, syncDeadline: CFTimeInterval
        ) {
            let height = body.frame.height
            let layout = RowLayout(rowID: rowID, key: key, height: height, content: body.content)
            let target = CGRect(x: 0, y: 0, width: body.contentWidth, height: height)
            if row.frame != target { row.frame = target }
            row.show(
                rowID: rowID, layout: layout, palette: palette, drawsWideBody: true, scale: scale,
                colorSpace: colorSpace, drawn: streamed)
            lastDrawnY = drawn
            lastVisibleY = visible
            lastContentWidth = body.contentWidth
            lastDrawsOffMain = drawsOffMain
            updateTiles(horizontalVisible: horizontalVisible, syncDeadline: syncDeadline)
        }

        /// Rasterizes newly exposed horizontal tiles and releases far ones as
        /// the user scrolls a wide code block or table sideways.
        func updateHorizontalViewport(_ horizontalVisible: ClosedRange<CGFloat>) {
            guard lastContentWidth > 0, !lastDrawnY.isNull else { return }
            let needsUpdate: Bool
            if let span = lastHorizontalDrawnSpan {
                needsUpdate =
                    horizontalVisible.lowerBound < span.lowerBound
                    || horizontalVisible.upperBound > span.upperBound
                    || abs(horizontalVisible.lowerBound - lastHorizontalDrawnX) > RowLayer.bandWidth / 4
            } else {
                needsUpdate = true
            }
            guard needsUpdate else { return }
            updateTiles(horizontalVisible: horizontalVisible, syncDeadline: 0)
        }

        private func updateTiles(horizontalVisible: ClosedRange<CGFloat>, syncDeadline: CFTimeInterval) {
            let overscan = RowLayer.bandWidth
            let drawMinX = max(0, horizontalVisible.lowerBound - overscan)
            let drawMaxX = min(lastContentWidth, horizontalVisible.upperBound + overscan)
            let drawWidth = max(0, drawMaxX - drawMinX)
            lastHorizontalDrawnX = horizontalVisible.lowerBound
            lastHorizontalDrawnSpan = drawMinX...drawMaxX
            // Clip both horizontally and vertically so wide/tall blocks only
            // rasterize and retain tiles near the viewport.
            let drawRect = CGRect(x: drawMinX, y: lastDrawnY.minY, width: drawWidth, height: lastDrawnY.height)
            let visibleRect =
                lastVisibleY.isNull
                ? .null
                : CGRect(
                    x: horizontalVisible.lowerBound, y: lastVisibleY.minY,
                    width: max(0, horizontalVisible.upperBound - horizontalVisible.lowerBound),
                    height: lastVisibleY.height)
            row.drawBands(
                in: drawRect, visible: visibleRect, offMain: lastDrawsOffMain, syncDeadline: syncDeadline)
            let releaseMarginY = lastVisibleY.isNull ? 512 : max(512, lastVisibleY.height)
            row.releaseBands(outside: drawRect.insetBy(dx: -RowLayer.bandWidth, dy: -releaseMarginY))
        }

        /// Clicks select text in the transcript, whose document is the
        /// scroller's superview: selection spans rows, not one block.
        private var transcriptDocument: NSView? { enclosingScrollView?.superview }

        override func mouseDown(with event: NSEvent) {
            transcriptDocument?.mouseDown(with: event) ?? super.mouseDown(with: event)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            transcriptDocument?.menu(for: event)
        }

        func showSelection(_ range: Range<Int>?, color: CGColor) {
            row.showSelection(range, color: color)
        }

        func resetForReuse() {
            lastDrawnY = .null
            lastVisibleY = .null
            lastContentWidth = 0
            lastHorizontalDrawnX = .nan
            lastHorizontalDrawnSpan = nil
            row.resetForReuse()
        }
    }
#endif
