#if os(iOS)
    import UIKit

    final class ChatTableHostView: ChatHorizontalDocumentScrollView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        private final class TableCanvasView: UIView {
            // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
            nonisolated deinit {}

            /// The canvas is one bitmap. Past this many pixels it is drawn at
            /// a lower scale instead of holding hundreds of megabytes for a
            /// table with dozens of long rows.
            private static let maximumPixelCount: CGFloat = 12_000_000

            var tableLayout: ChatTableLayout? {
                didSet {
                    guard tableLayout !== oldValue else { return }
                    applyScale()
                    setNeedsDisplay()
                }
            }

            override init(frame: CGRect) {
                super.init(frame: frame)
                // A scene can move to a screen of another scale.
                registerForTraitChanges([UITraitDisplayScale.self]) {
                    (canvas: TableCanvasView, _: UITraitCollection) in
                    canvas.applyScale()
                    canvas.setNeedsDisplay()
                }
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            private func applyScale() {
                let screenScale = max(1, traitCollection.displayScale)
                let area = (tableLayout?.size.width ?? 0) * (tableLayout?.size.height ?? 0)
                contentScaleFactor =
                    area * screenScale * screenScale > Self.maximumPixelCount
                    ? max(1, (Self.maximumPixelCount / area).squareRoot())
                    : screenScale
            }

            override func draw(_ rect: CGRect) {
                guard let tableLayout else { return }
                for cell in tableLayout.cells where cell.frame.intersects(rect) {
                    cell.text.draw(
                        with: cell.frame,
                        options: [.usesLineFragmentOrigin],
                        context: nil
                    )
                }
                UIColor.separator.setFill()
                for divider in tableLayout.dividerRects where divider.intersects(rect) {
                    UIRectFill(divider)
                }
            }
        }

        private let canvas = TableCanvasView()
        private var layoutID: String?
        private var table: ChatMarkdownTable?
        private weak var layoutStore: ChatTextLayoutStore?

        override init(frame: CGRect) {
            super.init(frame: frame)
            canvas.isOpaque = false
            canvas.backgroundColor = .clear
            canvas.contentMode = .redraw
            canvas.isAccessibilityElement = true
            canvas.accessibilityLabel = "Markdown table"
            canvas.accessibilityTraits = .staticText
            documentView = canvas
            // Cells are drawn, so a link in one is opened from the tap's
            // position. Scrolling either way cancels the tap.
            canvas.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(openLink(_:))))
        }

        func update(
            layoutID: String,
            table: ChatMarkdownTable,
            layoutStore: ChatTextLayoutStore
        ) {
            guard
                self.layoutID != layoutID || self.table != table
                    || self.layoutStore !== layoutStore
            else { return }
            self.layoutID = layoutID
            self.table = table
            self.layoutStore = layoutStore
            canvas.accessibilityValue = table.tabSeparatedText
            setNeedsLayout()
        }

        override func layoutSubviews() {
            if let layoutID, let table, let layoutStore {
                let layout = layoutStore.tableLayout(id: layoutID, table: table)
                if canvas.tableLayout !== layout {
                    canvas.tableLayout = layout
                    documentSize = layout.size
                }
            }
            super.layoutSubviews()
        }

        @objc private func openLink(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                let url = canvas.tableLayout?.link(at: recognizer.location(in: canvas))
            else { return }
            UIApplication.shared.open(url)
        }
    }
#endif
