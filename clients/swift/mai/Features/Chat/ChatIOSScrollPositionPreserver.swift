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
        private var userScrollStartY: CGFloat?
        private var lastOffsetY: CGFloat?
        private var lastViewport: Viewport?
        private var isBottomFollowingEnabled: () -> Bool = { false }
        private var noteUserScrollActivity: (Bool) -> Void = { _ in }
        private var noteUserReachedEnd: () -> Void = {}
        private var noteKeyboardScrollIntent: (Bool) -> Void = { _ in }

        /// The viewport a scroll happened in. An offset that moves along with
        /// it is the keyboard or a rotation, not the reader.
        private struct Viewport: Equatable {
            let size: CGSize
            let insets: UIEdgeInsets
            let contentHeight: CGFloat
        }

        func configure(
            isBottomFollowingEnabled: @escaping () -> Bool,
            noteUserScrollActivity: @escaping (Bool) -> Void,
            noteUserReachedEnd: @escaping () -> Void,
            noteKeyboardScrollIntent: @escaping (_ towardEnd: Bool) -> Void
        ) {
            self.isBottomFollowingEnabled = isBottomFollowingEnabled
            self.noteUserScrollActivity = noteUserScrollActivity
            self.noteUserReachedEnd = noteUserReachedEnd
            self.noteKeyboardScrollIntent = noteKeyboardScrollIntent
            document?.isBottomFollowingEnabled = isBottomFollowingEnabled
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
            document.isBottomFollowingEnabled = isBottomFollowingEnabled
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

        /// Returns false until a document with rows is attached.
        @discardableResult
        func pinToBottom(animated: Bool = false) -> Bool {
            document?.scrollToBottom(animated: animated) ?? false
        }

        // MARK: Reader input

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            document?.completeInitialBottomAlignment()
            if userScrollStartY == nil {
                userScrollStartY = scrollView.contentOffset.y
            }
            noteUserScrollActivity(true)
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

        private func finishUserScroll(in scrollView: UIScrollView) {
            guard let startY = userScrollStartY else { return }
            userScrollStartY = nil
            noteUserScrollActivity(false)
            if ChatScrollFollowPolicy.shouldRestoreFollowingAfterUserScroll(
                startY: startY,
                endY: scrollView.contentOffset.y,
                isNearBottom: document?.isNearBottom ?? false
            ) {
                noteUserReachedEnd()
            }
        }

        /// A status-bar tap, a hardware keyboard and VoiceOver scroll without
        /// a drag. Movement toward older content still means the reader left
        /// the end; movement the document or a viewport change made does not.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let offsetY = scrollView.contentOffset.y
            let viewport = Viewport(
                size: scrollView.bounds.size,
                insets: scrollView.adjustedContentInset,
                contentHeight: scrollView.contentSize.height
            )
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
                noteKeyboardScrollIntent(false)
            } else if offsetY > lastOffsetY + ChatScrollFollowPolicy.minimumMovement {
                noteKeyboardScrollIntent(true)
            }
        }
    }
#endif
