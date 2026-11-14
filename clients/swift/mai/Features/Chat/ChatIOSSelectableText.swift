#if os(iOS)
    import SwiftUI
    import UIKit

    /// Offers "Comment…" on a text selection in the transcript.
    final class ChatTextEditMenuDelegate: NSObject, UITextViewDelegate {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        var annotationContext: ChatAnnotationContext?

        /// The single-range callback is the one available on every supported
        /// iOS version; iOS 26 calls it with the selection's union range when
        /// the multi-range variant is not implemented.
        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let annotationContext, range.length > 0,
                NSMaxRange(range) <= textView.attributedText.length
            else {
                return UIMenu(children: suggestedActions)
            }
            let quote = textView.attributedText.attributedSubstring(from: range).string
            let comment = UIAction(
                title: "Comment…",
                image: UIImage(systemName: "text.bubble")
            ) { _ in
                annotationContext.model.beginComment(
                    quote: quote,
                    messageID: annotationContext.messageID,
                    role: annotationContext.role
                )
            }
            return UIMenu(children: suggestedActions + [comment])
        }
    }

    /// Selectable prose in a SwiftUI row, whose attributed content and
    /// measured height can be prepared before the row is mounted.
    struct ChatSelectableText: UIViewRepresentable {
        @Environment(\.chatAnnotationContext) private var annotationContext

        let layoutID: String
        let content: ChatTextContent
        let layoutStore: ChatTextLayoutStore

        func makeUIView(context: Context) -> ChatSelectableTextHostView {
            ChatSelectableTextHostView()
        }

        func updateUIView(_ uiView: ChatSelectableTextHostView, context: Context) {
            uiView.annotationContext = annotationContext
            uiView.update(layoutID: layoutID, content: content, layoutStore: layoutStore)
        }

        static func dismantleUIView(
            _ uiView: ChatSelectableTextHostView,
            coordinator: Void
        ) {
            uiView.dismantle()
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: ChatSelectableTextHostView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width, width > 0 else { return nil }
            let layout = layoutStore.layout(id: layoutID, content: content, width: width)
            return CGSize(width: width, height: layout.height)
        }
    }

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

    /// Quote bars and thematic breaks behind a prose run. Each is a small
    /// colored view: one view drawing them all would need a bitmap the size
    /// of the whole run.
    @MainActor
    final class ChatMarkdownDecorationViews {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        private var views: [UIView] = []

        func show(
            _ quoteBarRects: [CGRect],
            _ thematicBreakRects: [CGRect],
            in container: UIView,
            below textView: UIView
        ) {
            let count = quoteBarRects.count + thematicBreakRects.count
            while views.count > count {
                views.removeLast().removeFromSuperview()
            }
            while views.count < count {
                let view = UIView()
                view.isUserInteractionEnabled = false
                container.insertSubview(view, belowSubview: textView)
                views.append(view)
            }
            for (view, rect) in zip(views, quoteBarRects) {
                view.frame = rect
                view.backgroundColor = .secondaryLabel.withAlphaComponent(0.35)
                view.layer.cornerRadius = ChatMarkdownProseStyle.quoteBarWidth / 2
            }
            for (view, rect) in zip(views.dropFirst(quoteBarRects.count), thematicBreakRects) {
                view.frame = rect
                view.backgroundColor = .separator
                view.layer.cornerRadius = 0
            }
        }
    }
#endif
