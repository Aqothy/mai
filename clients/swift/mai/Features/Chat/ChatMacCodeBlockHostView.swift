#if os(macOS)
    import AppKit

    final class ChatMacCodeBlockHostView: ChatMacHorizontalDocumentScrollView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        private let textView: NSTextView
        private var layoutID: String?
        private var block: ChatMarkdownCodeBlock?
        private var theme: ChatCodeHighlightTheme?
        private weak var layoutStore: ChatTextLayoutStore?
        private var presentedLayout: ChatTextLayout?
        private var highlightTask: Task<Void, Never>?

        override init(frame frameRect: NSRect) {
            textView = ChatSelectableTextViewConfiguration.makeTextView()
            super.init(frame: frameRect)
            textView.textContainerInset = NSSize(
                width: ChatCodeBlockStyle.horizontalInset,
                height: 0
            )
            // Code never wraps; the container scrolls horizontally instead.
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.textContainer?.widthTracksTextView = false
            documentView = textView
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(
            layoutID: String,
            block: ChatMarkdownCodeBlock,
            theme: ChatCodeHighlightTheme,
            layoutStore: ChatTextLayoutStore
        ) {
            guard self.layoutID != layoutID || self.block != block
                || self.theme != theme || self.layoutStore !== layoutStore
            else { return }
            self.layoutID = layoutID
            self.block = block
            self.theme = theme
            self.layoutStore = layoutStore
            highlightTask?.cancel()
            highlightTask = nil
            needsLayout = true
        }

        func dismantle() {
            (textView as? ChatAnnotationTextView)?.annotationContext = nil
            highlightTask?.cancel()
            highlightTask = nil
            presentedLayout = nil
            layoutID = nil
            block = nil
            layoutStore = nil
        }

        override func layout() {
            if let layoutID, let block, let theme, let layoutStore {
                let (layout, isHighlighted) = layoutStore.codeLayout(
                    id: layoutID,
                    block: block,
                    theme: theme
                )
                if presentedLayout !== layout {
                    present(layout)
                }
                // A row realized before its page was prepared shows plain
                // text now and receives colors when the highlighter finishes.
                if !isHighlighted, highlightTask == nil {
                    let request = ChatCodeLayoutRequest(
                        id: layoutID,
                        block: block,
                        theme: theme
                    )
                    highlightTask = Task { [weak self, weak layoutStore] in
                        await layoutStore?.prepareCodeBlocks(requests: [request])
                        guard let self, !Task.isCancelled,
                            self.layoutID == request.id, self.block == request.block
                        else { return }
                        self.highlightTask = nil
                        self.needsLayout = true
                    }
                }
            }
            super.layout()
        }

        private func present(_ layout: ChatTextLayout) {
            textView.textStorage?.setAttributedString(layout.attributedString)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            presentedLayout = layout
            documentSize = NSSize(
                width: layout.contentWidth + 2 * ChatCodeBlockStyle.horizontalInset,
                height: layout.height + ChatCodeBlockStyle.bottomInset
            )
        }
    }
#endif
