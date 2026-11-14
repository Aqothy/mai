#if os(macOS)
    import AppKit

    /// A horizontal-only scroll container for a document of known size that
    /// lets vertical wheel gestures continue through the enclosing chat
    /// timeline.
    class ChatMacHorizontalDocumentScrollView: NSScrollView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        /// The document's natural size; the document is at least as wide as
        /// the clip view so short content still fills the row.
        var documentSize: NSSize = .zero {
            didSet {
                if documentSize != oldValue { needsLayout = true }
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            drawsBackground = false
            borderType = .noBorder
            hasHorizontalScroller = true
            hasVerticalScroller = false
            autohidesScrollers = true
            horizontalScrollElasticity = .automatic
            verticalScrollElasticity = .none
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            guard let documentView else { return }
            let size = NSSize(
                width: max(contentSize.width, documentSize.width),
                height: documentSize.height
            )
            if documentView.frame.size != size {
                documentView.setFrameSize(size)
            }
        }

        /// AppKit sends one diagonal trackpad event to the deepest scroll
        /// view. Split its axes at that boundary: this view owns x and the
        /// transcript owns y. A dominance heuristic makes the route flip
        /// during a gesture and drops the smaller axis, which is the
        /// stuttering/"stuck over code" behavior this wrapper prevents.
        override func scrollWheel(with event: NSEvent) {
            let hasHorizontalDelta = abs(event.scrollingDeltaX) > 0
            let hasVerticalDelta = abs(event.scrollingDeltaY) > 0

            if hasHorizontalDelta {
                super.scrollWheel(with: event)
            }
            if hasVerticalDelta, let enclosingVerticalScrollView {
                enclosingVerticalScrollView.scrollWheel(with: event)
            }
            if !hasHorizontalDelta, !hasVerticalDelta {
                super.scrollWheel(with: event)
            }
        }

        private var enclosingVerticalScrollView: NSScrollView? {
            var candidate = superview
            while let view = candidate {
                if let scrollView = view as? NSScrollView {
                    return scrollView
                }
                candidate = view.superview
            }
            return nil
        }
    }
#endif
