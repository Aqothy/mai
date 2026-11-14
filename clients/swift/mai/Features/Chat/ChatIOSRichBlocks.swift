#if os(iOS)
    import SwiftUI
    import UIKit

    // Native iOS rendering for settled rich Markdown blocks. These views
    // present a layout measured off the main actor by `ChatTextLayoutStore`,
    // so realizing a row is a frame assignment and its height is known
    // before it exists.

    // MARK: - Code blocks

    /// A fenced code block as one selectable, horizontally scrolling text
    /// view whose text and size were prepared off the main actor.
    struct ChatCodeBlockText: UIViewRepresentable {
        @Environment(\.chatAnnotationContext) private var annotationContext
        let layoutID: String
        let block: ChatMarkdownCodeBlock
        let theme: ChatCodeHighlightTheme
        let layoutStore: ChatTextLayoutStore

        func makeUIView(context: Context) -> ChatCodeBlockHostView {
            ChatCodeBlockHostView()
        }

        func updateUIView(_ uiView: ChatCodeBlockHostView, context: Context) {
            uiView.annotationContext = annotationContext
            uiView.update(layoutID: layoutID, block: block, theme: theme, layoutStore: layoutStore)
        }

        static func dismantleUIView(_ uiView: ChatCodeBlockHostView, coordinator: Void) {
            uiView.dismantle()
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: ChatCodeBlockHostView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width, width > 0 else { return nil }
            let layout = layoutStore.codeLayout(id: layoutID, block: block, theme: theme).layout
            return CGSize(width: width, height: layout.height + ChatCodeBlockStyle.bottomInset)
        }
    }

    final class ChatCodeBlockHostView: ChatHorizontalDocumentScrollView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        var annotationContext: ChatAnnotationContext? {
            didSet {
                menuDelegate.annotationContext = annotationContext
                textView.delegate = annotationContext == nil ? nil : menuDelegate
            }
        }

        private let menuDelegate = ChatTextEditMenuDelegate()
        private let textView = ChatSelectableTextViewConfiguration.makeTextView()
        private var layoutID: String?
        private var block: ChatMarkdownCodeBlock?
        private var theme: ChatCodeHighlightTheme?
        private weak var layoutStore: ChatTextLayoutStore?
        private var presentedLayout: ChatTextLayout?
        private var highlightTask: Task<Void, Never>?

        override init(frame: CGRect) {
            super.init(frame: frame)
            textView.textContainerInset = UIEdgeInsets(
                top: 0, left: ChatCodeBlockStyle.horizontalInset,
                bottom: 0, right: ChatCodeBlockStyle.horizontalInset)
            // Code never wraps; the container scrolls horizontally instead.
            textView.textContainer.widthTracksTextView = false
            textView.textContainer.size = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
            documentView = textView
        }

        func update(
            layoutID: String,
            block: ChatMarkdownCodeBlock,
            theme: ChatCodeHighlightTheme,
            layoutStore: ChatTextLayoutStore
        ) {
            guard
                self.layoutID != layoutID || self.block != block
                    || self.theme != theme || self.layoutStore !== layoutStore
            else { return }
            self.layoutID = layoutID
            self.block = block
            self.theme = theme
            self.layoutStore = layoutStore
            highlightTask?.cancel()
            highlightTask = nil
            setNeedsLayout()
        }

        func dismantle() {
            annotationContext = nil
            highlightTask?.cancel()
            highlightTask = nil
            presentedLayout = nil
            layoutID = nil
            block = nil
            layoutStore = nil
        }

        override func layoutSubviews() {
            if let layoutID, let block, let theme, let layoutStore {
                let (layout, isHighlighted) = layoutStore.codeLayout(
                    id: layoutID, block: block, theme: theme)
                if presentedLayout !== layout {
                    present(layout)
                }
                // A row realized before its page was prepared shows plain
                // text now and receives colors when the highlighter finishes.
                if !isHighlighted, highlightTask == nil {
                    let request = ChatCodeLayoutRequest(id: layoutID, block: block, theme: theme)
                    highlightTask = Task { [weak self, weak layoutStore] in
                        await layoutStore?.prepareCodeBlocks(requests: [request])
                        guard let self, !Task.isCancelled,
                            self.layoutID == request.id, self.block == request.block
                        else { return }
                        self.highlightTask = nil
                        self.setNeedsLayout()
                    }
                }
            }
            super.layoutSubviews()
        }

        private func present(_ layout: ChatTextLayout) {
            UIView.performWithoutAnimation {
                textView.attributedText = layout.attributedString
                textView.selectedRange = NSRange(location: 0, length: 0)
                documentSize = CGSize(
                    width: layout.contentWidth + 2 * ChatCodeBlockStyle.horizontalInset,
                    height: layout.height + ChatCodeBlockStyle.bottomInset)
            }
            presentedLayout = layout
        }
    }

    // MARK: - Tables

    /// A Markdown table drawn from a prepared `ChatTableLayout` inside the
    /// horizontal scroller. Cells are deliberately not selectable; the copy
    /// button above the table copies it whole.
    struct ChatTableBlock: UIViewRepresentable {
        let layoutID: String
        let table: ChatMarkdownTable
        let layoutStore: ChatTextLayoutStore

        func makeUIView(context: Context) -> ChatTableHostView {
            ChatTableHostView()
        }

        func updateUIView(_ uiView: ChatTableHostView, context: Context) {
            uiView.update(layoutID: layoutID, table: table, layoutStore: layoutStore)
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: ChatTableHostView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width, width > 0 else { return nil }
            let layout = layoutStore.tableLayout(id: layoutID, table: table)
            return CGSize(width: width, height: layout.size.height)
        }
    }

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

    // MARK: - Horizontal container

    /// A horizontal-only scroll container for a document of known size.
    /// UIKit sends a vertical pan over it to the enclosing chat timeline,
    /// because this view has nothing to scroll that way.
    class ChatHorizontalDocumentScrollView: UIScrollView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        var documentView: UIView? {
            didSet {
                oldValue?.removeFromSuperview()
                if let documentView {
                    addSubview(documentView)
                }
                setNeedsLayout()
            }
        }

        /// The document's natural size; the document is at least as wide as
        /// the viewport so short content still fills the row.
        var documentSize: CGSize = .zero {
            didSet {
                if documentSize != oldValue {
                    setNeedsLayout()
                }
            }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            showsVerticalScrollIndicator = false
            alwaysBounceVertical = false
            isDirectionalLockEnabled = true
            contentInsetAdjustmentBehavior = .never
            // Only the transcript may answer the status-bar tap.
            scrollsToTop = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let size = CGSize(
                width: max(bounds.width, documentSize.width),
                height: documentSize.height)
            if contentSize != size {
                contentSize = size
            }
            if let documentView, documentView.frame.size != size {
                documentView.frame = CGRect(origin: .zero, size: size)
            }
        }
    }
#endif
