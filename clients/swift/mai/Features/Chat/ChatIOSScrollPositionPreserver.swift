#if os(iOS)
    import UIKit

    /// Tells the chat's scroll state what the reader did with the transcript,
    /// and lands the first rows on the transcript's end.
    ///
    /// The document keeps the reading position itself, in the same pass that
    /// changes row geometry, and flags the offset changes it makes. Any other
    /// move in an unchanged viewport is the reader's, whatever the input: a
    /// drag, a fling, a status-bar tap, a hardware keyboard or VoiceOver.
    @MainActor
    final class ChatIOSScrollPositionPreserver: NSObject, UIScrollViewDelegate {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        private weak var document: (any ChatIOSScrollDocument)?
        /// Held until a document exists to carry the alignment out.
        private var pendingInitialBottomAlignment: (() -> Void)?
        private var viewportInsets = UIEdgeInsets.zero
        private var lastViewportTop: CGFloat?
        private var lastViewport: Viewport?
        private var handlers = ChatScrollIntentHandlers()

        /// The viewport a move happened in. An offset that moves along with
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
                lastViewportTop = nil
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
                // status-bar tap), which would otherwise carry on from the
                // end and take the reader away from it again.
                document.setContentOffset(document.contentOffset, animated: false)
            }
            return document.scrollToBottom(animated: animated)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let document, let top = document.viewportTop else { return }
            let viewport = Viewport(
                size: document.bounds.size, insets: document.adjustedContentInset)
            defer {
                lastViewportTop = top
                lastViewport = viewport
            }
            guard !document.isAdjustingScrollPosition, viewport == lastViewport,
                let lastViewportTop,
                abs(top - lastViewportTop) > ChatScrollFollowPolicy.minimumMovement
            else { return }
            // The reader took over from a jump to the end.
            document.endScrollAnimation()
            handlers.noteReaderScroll(from: lastViewportTop, in: document)
        }
    }
#endif
