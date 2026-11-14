#if os(iOS)
    import UIKit

    /// One prose run in a text view this host keeps for its lifetime. A
    /// recycled host shows another run by replacing the text view's content.
    final class ChatSelectableTextHostView: UIView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        /// Rows without an annotation context pay no delegate-callback cost.
        var annotationContext: ChatAnnotationContext? {
            didSet {
                menuDelegate.annotationContext = annotationContext
                textView.delegate = annotationContext == nil ? nil : menuDelegate
            }
        }

        private let menuDelegate = ChatTextEditMenuDelegate()
        private let textView = ChatSelectableTextViewConfiguration.makeTextView()
        private let decorations = ChatMarkdownDecorationViews()
        private var layoutID: String?
        private var content: ChatTextContent?
        private weak var layoutStore: ChatTextLayoutStore?
        private var presentedLayout: ChatTextLayout?
        private var presentedLayoutID: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(textView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(
            layoutID: String,
            content: ChatTextContent,
            layoutStore: ChatTextLayoutStore
        ) {
            guard
                self.layoutID != layoutID || self.content != content
                    || self.layoutStore !== layoutStore
            else { return }
            self.layoutID = layoutID
            self.content = content
            self.layoutStore = layoutStore
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let layoutID, let content, let layoutStore, bounds.width > 0 else { return }

            let layout = layoutStore.layout(id: layoutID, content: content, width: bounds.width)
            if presentedLayout !== layout {
                present(layout)
            } else if textView.frame != bounds {
                textView.frame = bounds
            }
        }

        func dismantle() {
            annotationContext = nil
            decorations.show([], [], in: self, below: textView)
            presentedLayout = nil
            presentedLayoutID = nil
            layoutID = nil
            content = nil
            layoutStore = nil
        }

        private func present(_ layout: ChatTextLayout) {
            let selection = presentedLayoutID == layoutID ? textView.selectedRange : nil
            UIView.performWithoutAnimation {
                // The view still holds the previous run. A new width would
                // lay that potentially large string out again, so it goes
                // first; a new height alone moves no text.
                if textView.frame.width != bounds.width {
                    textView.attributedText = nil
                }
                if textView.frame != bounds {
                    textView.frame = bounds
                }
                textView.attributedText = layout.attributedString
                decorations.show(
                    layout.quoteBarRects, layout.thematicBreakRects, in: self, below: textView)
            }
            if let selection, NSMaxRange(selection) <= layout.attributedString.length {
                textView.selectedRange = selection
            } else {
                textView.selectedRange = NSRange(location: 0, length: 0)
            }
            presentedLayout = layout
            presentedLayoutID = layoutID
        }
    }
#endif
