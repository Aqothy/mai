#if os(iOS)
    import UIKit
    import SwiftUI

    /// Pins the transcript to its end by writing the scroll offset directly.
    ///
    /// Bottom-following fires on every content-height change while a reply
    /// streams. Resolving the row identifier through `ScrollViewProxy` walks
    /// the entire ForEach identity list each time, which dominates the main
    /// thread on long transcripts; the offset arithmetic below is constant
    /// time.
    @MainActor
    final class ChatListBottomFollower {
        private weak var scrollView: UIScrollView?

        func attach(to scrollView: UIScrollView) {
            self.scrollView = scrollView
        }

        /// Returns false when no scroll view has been resolved yet, so the
        /// caller can fall back to a proxy-based scroll.
        func pinToBottom() -> Bool {
            guard let scrollView else { return false }
            let targetY = max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height
                    + scrollView.adjustedContentInset.bottom
                    - scrollView.bounds.height
            )
            if abs(scrollView.contentOffset.y - targetY) > 0.5 {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: targetY),
                    animated: false
                )
            }
            return true
        }
    }

    /// Resolves the `UICollectionView` backing the enclosing SwiftUI `List`.
    /// Placed in the List's background, it walks up from itself and searches
    /// each ancestor for the collection view under the marker's center, so a
    /// neighboring list or a code block's scroller can never win.
    struct ChatListCollectionViewIntrospector: UIViewRepresentable {
        let onResolve: (UICollectionView) -> Void

        func makeUIView(context: Context) -> FinderView {
            FinderView(onResolve: onResolve)
        }

        func updateUIView(_ uiView: FinderView, context: Context) {}

        final class FinderView: UIView {
            private let onResolve: (UICollectionView) -> Void
            private var resolvedCollectionView: UICollectionView?

            init(onResolve: @escaping (UICollectionView) -> Void) {
                self.onResolve = onResolve
                super.init(frame: .zero)
                isUserInteractionEnabled = false
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) {
                fatalError("init(coder:) is not supported")
            }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                resolveIfNeeded()
            }

            override func didMoveToSuperview() {
                super.didMoveToSuperview()
                resolveIfNeeded()
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                resolveIfNeeded()
            }

            private func resolveIfNeeded() {
                guard resolvedCollectionView == nil, window != nil else {
                    return
                }
                var ancestor = superview
                while let current = ancestor {
                    if let collectionView = firstCollectionView(in: current) {
                        resolvedCollectionView = collectionView
                        onResolve(collectionView)
                        return
                    }
                    ancestor = current.superview
                }
            }

            private func firstCollectionView(
                in root: UIView
            ) -> UICollectionView? {
                var queue: [UIView] = [root]
                while !queue.isEmpty {
                    let view = queue.removeFirst()
                    if let collectionView = view as? UICollectionView {
                        let center = convert(
                            CGPoint(x: bounds.midX, y: bounds.midY),
                            to: collectionView
                        )
                        if collectionView.bounds.contains(center) {
                            return collectionView
                        }
                        continue
                    }
                    queue.append(contentsOf: view.subviews)
                }
                return nil
            }
        }
    }
#endif
