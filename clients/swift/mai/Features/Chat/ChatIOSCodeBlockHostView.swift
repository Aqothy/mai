#if os(iOS)
    import UIKit

    /// A settled code block's text view in its horizontal scroller. It
    /// presents a layout measured off the main actor by
    /// `ChatTextLayoutStore`, so realizing a row is a frame assignment and
    /// its height is known before it exists.
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
#endif
