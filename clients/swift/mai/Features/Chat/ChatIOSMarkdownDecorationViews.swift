#if os(iOS)
    import UIKit

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
