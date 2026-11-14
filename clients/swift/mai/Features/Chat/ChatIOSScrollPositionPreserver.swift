#if os(iOS)
    import UIKit

    /// Tells the chat's scroll state what the reader did with the transcript:
    /// a drag, a keyboard or accessibility scroll, or reaching the end.
    ///
    /// The document keeps the reading position itself, in the same pass that
    /// changes row geometry. This controller only separates the reader's
    /// intent from the offset changes layout makes, and lands the first rows
    /// on the transcript's end.
    @MainActor
    final class ChatIOSScrollPositionPreserver: NSObject, UIScrollViewDelegate {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        private weak var document: (any ChatIOSScrollDocument)?
        /// Held until a document exists to carry the alignment out.
        private var pendingInitialBottomAlignment: (() -> Void)?
        private var viewportInsets = UIEdgeInsets.zero
        private var userScrollStartY: CGFloat?
        private var lastOffsetY: CGFloat?
        private var lastViewport: Viewport?
        private var handlers = ChatScrollIntentHandlers()

        /// The viewport a scroll happened in. An offset that moves along with
        /// it is the keyboard or a rotation, not the reader.
        private struct Viewport: Equatable {
            let size: CGSize
            let insets: UIEdgeInsets
        }

        func configure(_ handlers: ChatScrollIntentHandlers) {
            self.handlers = handlers
            document?.isBottomFollowingEnabled = handlers.isBottomFollowingEnabled
        }

        /// Called after every install, so it must converge when repeated.
        func attach(to document: any ChatIOSScrollDocument) {
            if self.document !== document {
                self.document?.delegate = nil
                userScrollStartY = nil
                lastOffsetY = nil
                lastViewport = nil
                self.document = document
                document.delegate = self
            }
            document.isBottomFollowingEnabled = handlers.isBottomFollowingEnabled
            document.setViewportInsets(viewportInsets)
            if let completion = pendingInitialBottomAlignment {
                pendingInitialBottomAlignment = nil
                document.beginInitialBottomAlignment(completion: completion)
            }
        }

        /// Shows the transcript's end once its first rows exist.
        func beginInitialBottomAlignment(completion: @escaping () -> Void) {
            if let document {
                document.beginInitialBottomAlignment(completion: completion)
            } else {
                pendingInitialBottomAlignment = completion
            }
        }

        /// The bars and keyboard that cover the transcript's top and bottom.
        /// SwiftUI reports no safe area to a view that ignores it, so the
        /// scroll view cannot find these itself. Handed over here rather
        /// than through the transcript's inputs, which would rebuild its
        /// rows for every keyboard movement.
        func setViewportInsets(_ insets: UIEdgeInsets) {
            viewportInsets = insets
            document?.setViewportInsets(insets)
        }

        /// Returns false until a document with rows is attached.
        @discardableResult
        func pinToBottom(animated: Bool = false) -> Bool {
            guard let document else { return false }
            if !document.isTracking {
                // Moving to the end ends whatever the reader's last scroll
                // still does: a fling, or UIKit's own scroll animation (a
                // status-bar tap), which assigning the offset leaves running.
                // UIKit reports no end for either when stopped this way.
                document.setContentOffset(document.contentOffset, animated: false)
                finishUserScroll(in: document)
            }
            return document.scrollToBottom(animated: animated)
        }

        // MARK: Reader input

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            document?.endScrollAnimation()
            document?.completeInitialBottomAlignment()
            if userScrollStartY == nil {
                userScrollStartY = scrollView.contentOffset.y
            }
            handlers.noteUserScrollActivity(true)
        }

        func scrollViewDidEndDragging(
            _ scrollView: UIScrollView,
            willDecelerate decelerate: Bool
        ) {
            if !decelerate {
                finishUserScroll(in: scrollView)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishUserScroll(in: scrollView)
        }

        /// The tap's own scroll takes over from a running jump to the end
        /// or a fling, whose end UIKit then does not report.
        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            document?.endScrollAnimation()
            if !scrollView.isTracking {
                finishUserScroll(in: scrollView)
            }
            return true
        }

        private func finishUserScroll(in scrollView: UIScrollView) {
            guard let startY = userScrollStartY else { return }
            userScrollStartY = nil
            handlers.finishUserScroll(
                startY: startY, endY: scrollView.contentOffset.y,
                isNearBottom: document?.isNearBottom ?? false)
        }

        /// A status-bar tap, a hardware keyboard and VoiceOver scroll without
        /// a drag. Movement toward older content still means the reader left
        /// the end; movement the document or a viewport change made does not.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let offsetY = scrollView.contentOffset.y
            let viewport = Viewport(
                size: scrollView.bounds.size, insets: scrollView.adjustedContentInset)
            defer {
                lastOffsetY = offsetY
                lastViewport = viewport
            }
            guard userScrollStartY == nil,
                !scrollView.isTracking, !scrollView.isDecelerating,
                document?.isAdjustingScrollPosition == false,
                viewport == lastViewport,
                let lastOffsetY
            else { return }

            if offsetY < lastOffsetY - ChatScrollFollowPolicy.minimumMovement {
                handlers.noteKeyboardScrollIntent(false)
            } else if offsetY > lastOffsetY + ChatScrollFollowPolicy.minimumMovement {
                handlers.noteKeyboardScrollIntent(true)
            }
        }
    }
#endif
