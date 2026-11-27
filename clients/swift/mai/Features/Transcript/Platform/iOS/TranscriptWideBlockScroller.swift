#if os(iOS)
    import UIKit

    /// The horizontal scroller of a code block or table wider than its row,
    /// pooled by the transcript. Only its scroll bar takes touches: its pan
    /// sits on the transcript's text view, so a long press inside the block
    /// starts a selection like anywhere else (see
    /// `TranscriptScrollView.makeWideBlockScroller`).
    /// Vertical pans pass to the transcript on their own: this view has
    /// nothing to scroll vertically (PLAN 3.9). Only the transcript answers
    /// the status-bar tap.
    final class TranscriptWideBlockScroller: UIScrollView, UIScrollViewDelegate {
        private let body = UIView()
        private let row = RowLayer()
        private(set) var rowID: String?
        private var lastDrawnY: CGRect = .null
        private var lastVisibleY: CGRect = .null
        private var lastContentWidth: CGFloat = 0
        private var lastHorizontalDrawnX: CGFloat = .nan
        private var lastHorizontalDrawnSpan: ClosedRange<CGFloat>?
        /// Called when the horizontal offset changes so UIKit selection rects
        /// and handles follow the scrolled content.
        var onHorizontalScroll: (() -> Void)?
        /// The reader scrolled this block sideways (never called for
        /// `scroll(toX:)`, so restored offsets do not echo).
        var onReaderScroll: ((TranscriptWideBlockScroller) -> Void)?
        private var isSettingOffset = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            alwaysBounceVertical = false
            alwaysBounceHorizontal = false
            isDirectionalLockEnabled = true
            showsVerticalScrollIndicator = false
            scrollsToTop = false
            backgroundColor = .clear
            body.isUserInteractionEnabled = false
            body.layer.addSublayer(row)
            addSubview(body)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// Only the scroll bar's strip at the bottom takes touches, so its
        /// indicator can be grabbed; the rest of the block passes them to the
        /// text view underneath. The strip holds no text: code ends 16 pt and
        /// table cells 12 pt above the bottom (`TextStyle`).
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            super.point(inside: point, with: event) && point.y >= bounds.maxY - 12
        }

        /// The pan hears every touch on the text view: it scrolls this block
        /// only for a drag that starts on it.
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === panGestureRecognizer {
                guard rowID != nil, !isHidden else { return false }
                let now = panGestureRecognizer.location(in: self)
                let moved = panGestureRecognizer.translation(in: self)
                guard bounds.contains(CGPoint(x: now.x - moved.x, y: now.y - moved.y)) else { return false }
            }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateHorizontalTilesIfNeeded()
            if !isSettingOffset {
                onHorizontalScroll?()
                onReaderScroll?(self)
            }
        }

        /// Scrolls to `x` (clamped to the content) without reporting it.
        func scroll(toX x: CGFloat) {
            let clamped = min(max(0, x), max(0, contentSize.width - bounds.width))
            guard abs(contentOffset.x - clamped) > 0.5 else { return }
            isSettingOffset = true
            contentOffset = CGPoint(x: clamped, y: contentOffset.y)
            isSettingOffset = false
        }

        /// Shows `wide` for `rowID`; a row new to this scroller starts at its
        /// block's offset.
        func show(
            rowID: String, offset: CGFloat, body wide: WideBlockBody, key: RowLayoutKey,
            palette: TextPalette, scale: CGFloat, colorSpace: CGColorSpace, drawn: CGRect,
            visible: CGRect, streamed: DrawnBands?
        ) {
            let isNewRow = self.rowID != rowID
            self.rowID = rowID
            let height = wide.frame.height
            let targetSize = CGSize(width: max(bounds.width, wide.contentWidth), height: height)
            if contentSize != targetSize {
                contentSize = targetSize
                body.frame = CGRect(origin: .zero, size: targetSize)
            }
            if isNewRow { scroll(toX: offset) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let rowFrame = CGRect(x: 0, y: 0, width: wide.contentWidth, height: height)
            if row.frame != rowFrame { row.frame = rowFrame }
            row.show(
                rowID: rowID, layout: RowLayout(rowID: rowID, key: key, height: height, content: wide.content),
                palette: palette, drawsWideBody: true, scale: scale, colorSpace: colorSpace, drawn: streamed)
            lastDrawnY = drawn
            lastVisibleY = visible
            lastContentWidth = wide.contentWidth
            updateTiles()
            CATransaction.commit()
        }

        private func updateHorizontalTilesIfNeeded() {
            guard lastContentWidth > 0, !lastDrawnY.isNull else { return }
            let visMinX = max(0, contentOffset.x)
            let visMaxX = visMinX + bounds.width
            let needsUpdate: Bool
            if let span = lastHorizontalDrawnSpan {
                needsUpdate =
                    visMinX < span.lowerBound || visMaxX > span.upperBound
                    || abs(visMinX - lastHorizontalDrawnX) > RowLayer.bandWidth / 4
            } else {
                needsUpdate = true
            }
            guard needsUpdate else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateTiles()
            CATransaction.commit()
        }

        private func updateTiles() {
            let visMinX = max(0, contentOffset.x)
            let visWidth = max(bounds.width, frame.width)
            let overscan = RowLayer.bandWidth
            let drawMinX = max(0, visMinX - overscan)
            let drawMaxX = min(lastContentWidth, visMinX + visWidth + overscan)
            let drawWidth = max(0, drawMaxX - drawMinX)
            lastHorizontalDrawnX = visMinX
            lastHorizontalDrawnSpan = drawMinX...drawMaxX
            let drawRect = CGRect(x: drawMinX, y: lastDrawnY.minY, width: drawWidth, height: lastDrawnY.height)
            let visibleRect =
                lastVisibleY.isNull
                ? .null
                : CGRect(x: visMinX, y: lastVisibleY.minY, width: visWidth, height: lastVisibleY.height)
            row.drawBands(in: drawRect, visible: visibleRect)
            let releaseMarginY = lastVisibleY.isNull ? 512 : max(512, lastVisibleY.height)
            row.releaseBands(outside: drawRect.insetBy(dx: -RowLayer.bandWidth, dy: -releaseMarginY))
        }

        func showSelection(_ range: Range<Int>?, color: CGColor) {
            row.showSelection(range, color: color)
        }

        func releaseOffscreenBands(keeping visible: CGRect) {
            let visMinX = max(0, contentOffset.x)
            row.releaseBands(
                outside: CGRect(x: visMinX, y: visible.minY, width: max(bounds.width, frame.width), height: visible.height))
            lastHorizontalDrawnX = .nan
            lastHorizontalDrawnSpan = nil
        }

        /// How far the body is scrolled: hit testing adds it to a point.
        var scrollX: CGFloat { contentOffset.x }

        func resetForReuse() {
            rowID = nil
            onReaderScroll = nil
            onHorizontalScroll = nil
            lastDrawnY = .null
            lastVisibleY = .null
            lastContentWidth = 0
            lastHorizontalDrawnX = .nan
            lastHorizontalDrawnSpan = nil
            // Unlike assigning the offset, this also ends a fling, which
            // would otherwise carry on into the next row shown here.
            setContentOffset(.zero, animated: false)
            row.resetForReuse()
        }
    }
#endif
