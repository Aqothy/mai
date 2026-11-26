#if os(macOS)
    import AppKit

    /// The horizontal scroller of a code block or table wider than its row,
    /// pooled by the transcript document. The body draws in a row layer of
    /// its own, from the block's layout.
    ///
    /// AppKit sends a whole trackpad gesture to the innermost scroll view
    /// under the pointer, so it is routed here, once per gesture: the axis of
    /// its first movement decides, and the gesture (its momentum included)
    /// stays with it. A vertical swipe scrolls only the transcript however
    /// it drifts sideways, a sideways one only this block, as in browsers
    /// (scroll latching). Deciding per event instead flips mid-gesture and
    /// stutters. A wheel without phases routes each event by its axis.
    final class TranscriptWideBlockScrollView: NSScrollView {
        weak var transcriptScrollView: NSScrollView?
        private let body = TranscriptWideBlockBodyView()
        private(set) var rowID: String?
        /// The reader scrolled this block sideways (never called for
        /// `scroll(toX:)`, so restored offsets do not echo).
        var onReaderScroll: ((TranscriptWideBlockScrollView) -> Void)?
        private var isSettingOffset = false
        /// The axis the trackpad gesture in progress was latched to.
        private var gestureAxis: NSEvent.GestureAxis?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            drawsBackground = false
            borderType = .noBorder
            hasHorizontalScroller = true
            hasVerticalScroller = false
            autohidesScrollers = true
            horizontalScrollElasticity = .automatic
            verticalScrollElasticity = .none
            documentView = body
            contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(horizontalClipDidScroll),
                name: NSView.boundsDidChangeNotification, object: contentView)
        }

        @objc private func horizontalClipDidScroll() {
            let bounds = contentView.bounds
            let minX = max(0, bounds.minX)
            let maxX = max(minX, minX + bounds.width)
            body.updateHorizontalViewport(minX...maxX)
            if !isSettingOffset { onReaderScroll?(self) }
        }

        /// Scrolls to `x` (clamped to the content) without reporting it.
        func scroll(toX x: CGFloat) {
            let clamped = min(max(0, x), max(0, body.frame.width - contentView.bounds.width))
            guard abs(contentView.bounds.origin.x - clamped) > 0.5 else { return }
            isSettingOffset = true
            contentView.scroll(to: NSPoint(x: clamped, y: contentView.bounds.origin.y))
            reflectScrolledClipView(contentView)
            isSettingOffset = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// Shows `wide` for `rowID`; a row new to this scroller starts at its
        /// block's offset.
        func show(
            rowID: String, offset: CGFloat, body wide: WideBlockBody, key: RowLayoutKey,
            palette: TextPalette, scale: CGFloat, colorSpace: CGColorSpace, drawsOffMain: Bool, drawn: CGRect,
            visible: CGRect, streamed: DrawnBands?, syncDeadline: CFTimeInterval
        ) {
            let isNewRow = self.rowID != rowID
            self.rowID = rowID
            let target = NSRect(x: 0, y: 0, width: max(frame.width, wide.contentWidth), height: wide.frame.height)
            let resized = body.frame != target
            if resized { body.frame = target }
            if isNewRow { scroll(toX: offset) }
            let visMinX = max(0, contentView.bounds.minX)
            let visWidth = max(frame.width, contentView.bounds.width)
            body.show(
                rowID: rowID, body: wide, key: key, palette: palette, scale: scale, colorSpace: colorSpace,
                drawsOffMain: drawsOffMain, drawn: drawn, visible: visible,
                horizontalVisible: visMinX...(visMinX + visWidth), streamed: streamed, syncDeadline: syncDeadline)
            if resized { reflectScrolledClipView(contentView) }
        }

        func showSelection(_ range: Range<Int>?, color: CGColor) {
            body.showSelection(range, color: color)
        }

        /// How far the body is scrolled: hit testing adds it to a point.
        var scrollX: CGFloat { contentView.bounds.origin.x }

        func resetForReuse() {
            rowID = nil
            onReaderScroll = nil
            gestureAxis = nil
            body.resetForReuse()
            contentView.scroll(to: .zero)
            reflectScrolledClipView(contentView)
        }

        override func scrollWheel(with event: NSEvent) {
            let dx = abs(event.scrollingDeltaX)
            let dy = abs(event.scrollingDeltaY)
            let isGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
            if !isGesture {
                if dx > dy { super.scrollWheel(with: event) } else { transcriptScrollView?.scrollWheel(with: event) }
                return
            }
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) { gestureAxis = nil }
            if gestureAxis == nil, dx != 0 || dy != 0 { gestureAxis = dx > dy ? .horizontal : .vertical }
            if gestureAxis == .horizontal {
                super.scrollWheel(with: event)
            } else {
                transcriptScrollView?.scrollWheel(with: event)
            }
        }
    }
#endif
