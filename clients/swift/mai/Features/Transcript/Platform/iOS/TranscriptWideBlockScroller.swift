#if os(iOS)
    import UIKit

    /// The horizontal scroller of a code block or table wider than its row,
    /// pooled by the transcript. Vertical pans pass to the transcript on
    /// their own: this view has nothing to scroll vertically (PLAN 3.9). Only
    /// the transcript answers the status-bar tap.
    final class TranscriptWideBlockScroller: UIScrollView, UIScrollViewDelegate {
        private let body = UIView()
        private let row = RowLayer()
        private(set) var rowID: String?
        /// Called when the horizontal offset changes so UIKit selection rects
        /// and handles follow the scrolled content.
        var onHorizontalScroll: (() -> Void)?

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

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            onHorizontalScroll?()
        }

        func show(
            rowID: String, body wide: WideBlockBody, key: RowLayoutKey, palette: TextPalette, scale: CGFloat,
            colorSpace: CGColorSpace, drawsOffMain: Bool, drawn: CGRect, visible: CGRect, streamed: DrawnBands?
        ) {
            if self.rowID != rowID { contentOffset = .zero }
            self.rowID = rowID
            let height = wide.frame.height
            let targetSize = CGSize(width: max(bounds.width, wide.contentWidth), height: height)
            if contentSize != targetSize {
                contentSize = targetSize
                body.frame = CGRect(origin: .zero, size: targetSize)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let rowFrame = CGRect(x: 0, y: 0, width: wide.contentWidth, height: height)
            if row.frame != rowFrame { row.frame = rowFrame }
            row.show(
                rowID: rowID, layout: RowLayout(rowID: rowID, key: key, height: height, content: wide.content),
                palette: palette, drawsWideBody: true, scale: scale, colorSpace: colorSpace, drawn: streamed)
            let drawRect = CGRect(x: 0, y: drawn.minY, width: wide.contentWidth, height: drawn.height)
            let visibleRect =
                visible.isNull ? .null : CGRect(x: 0, y: visible.minY, width: wide.contentWidth, height: visible.height)
            row.drawBands(in: drawRect, visible: visibleRect, offMain: drawsOffMain)
            let releaseMargin = visible.isNull ? 512 : max(512, visible.height)
            row.releaseBands(outside: drawRect.insetBy(dx: 0, dy: -releaseMargin))
            CATransaction.commit()
        }

        func showSelection(_ range: Range<Int>?, color: CGColor) {
            row.showSelection(range, color: color)
        }

        func releaseOffscreenBands(keeping visible: CGRect) {
            row.releaseBands(outside: CGRect(x: 0, y: visible.minY, width: row.bounds.width, height: visible.height))
        }

        /// How far the body is scrolled: hit testing adds it to a point.
        var scrollX: CGFloat { contentOffset.x }

        func resetForReuse() {
            rowID = nil
            onHorizontalScroll = nil
            row.resetForReuse()
        }
    }
#endif
