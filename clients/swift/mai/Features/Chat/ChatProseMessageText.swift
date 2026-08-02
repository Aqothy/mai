#if os(iOS)
    import SwiftUI
    import UIKit

    /// Selectable prose backed by a pre-laid-out TextKit stack from
    /// `ChatProseLayoutStore`. Because the layout (and therefore the height)
    /// is computed before the row realizes, scrolling past an essay-sized
    /// prose run costs view creation and drawing only — the pattern that
    /// off-main-thread list frameworks use, expressed in SwiftUI.
    struct ChatProseMessageText: UIViewRepresentable {
        let source: String

        func makeUIView(context: Context) -> ChatProseTextHostView {
            ChatProseTextHostView()
        }

        func updateUIView(_ uiView: ChatProseTextHostView, context: Context) {
            uiView.source = source
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: ChatProseTextHostView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width, width > 0 else { return nil }
            let layout = ChatProseLayoutStore.shared.layout(
                source: source,
                width: width
            )
            return CGSize(width: width, height: layout.height)
        }
    }

    /// Hosts the one `UITextView` bound to the current layout. A TextKit 1
    /// container backs a single text view, so presentation swaps rebuild the
    /// text view rather than mutating it.
    final class ChatProseTextHostView: UIView {
        var source: String? {
            didSet {
                guard source != oldValue else { return }
                setNeedsLayout()
            }
        }

        private var textView: UITextView?
        private var presentedLayout: ChatProseTextLayout?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let source, bounds.width > 0 else { return }

            let layout = ChatProseLayoutStore.shared.layout(
                source: source,
                width: bounds.width
            )
            if presentedLayout !== layout {
                present(layout, source: source)
            }
            textView?.frame = bounds
        }

        deinit {
            presentedLayout?.isAttached = false
        }

        private func present(_ layout: ChatProseTextLayout, source: String) {
            presentedLayout?.isAttached = false
            textView?.removeFromSuperview()

            // A container already driving another live text view cannot be
            // shared; fall back to a private duplicate (same content, fresh
            // stack) rather than corrupting the visible one.
            let adopted = layout.isAttached
                ? ChatProseTextLayout(source: source, width: layout.width)
                : layout
            adopted.isAttached = true

            let view = UITextView(frame: bounds, textContainer: adopted.textContainer)
            view.isEditable = false
            view.isSelectable = true
            view.isScrollEnabled = false
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            // The store rebuilds layouts on Dynamic Type changes; letting the
            // text view rescale independently would fight the cached heights.
            view.adjustsFontForContentSizeCategory = false

            addSubview(view)
            textView = view
            presentedLayout = adopted
        }
    }
#endif
