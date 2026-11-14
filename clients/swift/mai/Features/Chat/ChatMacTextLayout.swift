#if os(macOS)
    import AppKit
    import SwiftUI

    /// Native macOS range selection for chat prose.
    struct ChatSelectableText: NSViewRepresentable {
        @Environment(\.chatAnnotationContext) private var annotationContext
        let layoutID: String
        let content: ChatTextContent
        let layoutStore: ChatTextLayoutStore

        func makeNSView(context: Context) -> ChatSelectableTextHostView {
            ChatSelectableTextHostView()
        }

        func updateNSView(
            _ nsView: ChatSelectableTextHostView,
            context: Context
        ) {
            nsView.annotationContext = annotationContext
            nsView.update(layoutID: layoutID, content: content, layoutStore: layoutStore)
        }

        static func dismantleNSView(
            _ nsView: ChatSelectableTextHostView,
            coordinator: Void
        ) {
            nsView.dismantle()
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: ChatSelectableTextHostView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width, width > 0 else { return nil }
            let layout = layoutStore.layout(id: layoutID, content: content, width: width)
            return CGSize(width: width, height: layout.height)
        }
    }

    final class ChatSelectableTextHostView: NSView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        private final class MarkdownDecorationView: NSView {
            // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
            nonisolated deinit {}

            var quoteBarRects: [NSRect] = []
            var thematicBreakRects: [NSRect] = []

            override var isFlipped: Bool { true }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func draw(_ dirtyRect: NSRect) {
                NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
                for rect in quoteBarRects where rect.intersects(dirtyRect) {
                    NSBezierPath(
                        roundedRect: rect,
                        xRadius: ChatMarkdownProseStyle.quoteBarWidth / 2,
                        yRadius: ChatMarkdownProseStyle.quoteBarWidth / 2
                    ).fill()
                }

                NSColor.separatorColor.setFill()
                for rect in thematicBreakRects where rect.intersects(dirtyRect) {
                    NSBezierPath(rect: rect).fill()
                }
            }
        }

        var annotationContext: ChatAnnotationContext? {
            didSet { (textView as? ChatAnnotationTextView)?.annotationContext = annotationContext }
        }

        private var decorationView: MarkdownDecorationView?
        private let textView: NSTextView
        private var layoutID: String?
        private var content: ChatTextContent?
        private weak var layoutStore: ChatTextLayoutStore?
        private var presentedLayout: ChatTextLayout?
        private var presentedLayoutID: String?

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            textView = ChatSelectableTextViewConfiguration.makeTextView()
            super.init(frame: frameRect)
            addSubview(textView)
        }

        convenience init() {
            self.init(frame: .zero)
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
            guard self.layoutID != layoutID || self.content != content
                || self.layoutStore !== layoutStore
            else { return }
            self.layoutID = layoutID
            self.content = content
            self.layoutStore = layoutStore
            needsLayout = true
        }

        override func layout() {
            super.layout()
            guard let layoutID, let content, let layoutStore,
                bounds.width > 0, bounds.height >= 0
            else { return }

            let layout = layoutStore.layout(id: layoutID, content: content, width: bounds.width)
            if presentedLayout !== layout {
                present(layout)
            }
            Self.resize(textView, to: bounds)
            decorationView?.frame = bounds
        }

        func dismantle() {
            annotationContext = nil
            decorationView?.removeFromSuperview()
            decorationView = nil
            presentedLayout = nil
            presentedLayoutID = nil
            layoutID = nil
            content = nil
            layoutStore = nil
        }

        private func present(_ layout: ChatTextLayout) {
            let selection: NSRange? =
                presentedLayoutID == layoutID
                ? textView.selectedRange()
                : nil
            Self.resize(textView, to: bounds)
            textView.textStorage?.setAttributedString(layout.attributedString)
            if let selection,
                NSMaxRange(selection) <= layout.attributedString.length
            {
                textView.setSelectedRange(selection)
            } else {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }

            decorationView?.removeFromSuperview()
            decorationView = nil
            if layout.hasMarkdownDecorations {
                let decorations = MarkdownDecorationView(frame: bounds)
                decorations.setAccessibilityElement(false)
                decorations.quoteBarRects = layout.quoteBarRects
                decorations.thematicBreakRects = layout.thematicBreakRects
                addSubview(
                    decorations,
                    positioned: .below,
                    relativeTo: textView
                )
                decorationView = decorations
            }
            presentedLayout = layout
            presentedLayoutID = layoutID
        }

        private static func resize(_ view: NSTextView, to bounds: NSRect) {
            if view.frame != bounds {
                view.frame = bounds
            }
            let containerSize = NSSize(
                width: max(1, bounds.width),
                height: .greatestFiniteMagnitude
            )
            if view.textContainer?.containerSize != containerSize {
                view.textContainer?.containerSize = containerSize
            }
        }
    }
#endif
