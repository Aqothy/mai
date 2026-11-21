#if os(iOS)
    import UIKit

    /// The horizontal scroller of a code block or table wider than its row,
    /// pooled by the transcript. Vertical pans pass to the transcript on
    /// their own: this view has nothing to scroll vertically (PLAN 3.9). Only
    /// the transcript answers the status-bar tap.
    final class TranscriptWideBlockScroller: UIScrollView {
        private let body = UIView()
        private let row = RowLayer()
        private(set) var rowID: String?
        private var shown: Shown?

        /// What the body shows, so placing an unchanged block again is free.
        private struct Shown: Equatable {
            let rowID: String
            let key: RowLayoutKey
            let colorsAreDark: Bool?
            let isHighlighted: Bool
            let isDark: Bool
            let scale: CGFloat
            let colorSpace: CGColorSpace
            let width: CGFloat
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
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

        func show(
            rowID: String, body wide: WideBlockBody, key: RowLayoutKey, palette: TextPalette, scale: CGFloat,
            colorSpace: CGColorSpace, drawsOffMain: Bool, isVisible: Bool
        ) {
            let shown = Shown(
                rowID: rowID, key: key, colorsAreDark: wide.content.colorsAreDark,
                isHighlighted: wide.content.isHighlighted, isDark: palette.isDark,
                scale: scale, colorSpace: colorSpace, width: bounds.width)
            guard shown != self.shown else { return }
            if self.rowID != rowID { contentOffset = .zero }
            self.shown = shown
            self.rowID = rowID
            let height = wide.frame.height
            contentSize = CGSize(width: max(bounds.width, wide.contentWidth), height: height)
            body.frame = CGRect(origin: .zero, size: contentSize)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            row.frame = CGRect(x: 0, y: 0, width: wide.contentWidth, height: height)
            row.show(
                rowID: rowID, layout: RowLayout(rowID: rowID, key: key, height: height, content: wide.content),
                palette: palette, drawsWideBody: true, scale: scale, colorSpace: colorSpace)
            // On screen already, it draws now rather than show a blank block.
            row.drawBands(in: row.bounds, visible: isVisible ? row.bounds : .null, offMain: drawsOffMain)
            CATransaction.commit()
        }

        func showSelection(_ range: Range<Int>?, color: CGColor) {
            row.showSelection(range, color: color)
        }

        /// How far the body is scrolled: hit testing adds it to a point.
        var scrollX: CGFloat { contentOffset.x }

        func resetForReuse() {
            rowID = nil
            shown = nil
            row.resetForReuse()
        }
    }
#endif
