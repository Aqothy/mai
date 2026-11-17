#if os(macOS)
    import AppKit

    /// Tells the chat's scroll state what the reader did with the transcript,
    /// and lands the first rows on the transcript's end.
    ///
    /// The document keeps the reading position itself, in the same pass that
    /// changes row geometry, and reports any clip move that neither it nor a
    /// viewport change made: the reader's, whatever the input, a trackpad
    /// and its momentum, a wheel, the scroller or a key.
    @MainActor
    final class ChatMacScrollPositionPreserver {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        private weak var document: (any ChatMacScrollDocument)?
        /// Held until a document exists to carry the alignment out.
        private var pendingInitialBottomAlignment: (() -> Void)?
        private var handlers = ChatScrollIntentHandlers()

        func configure(_ handlers: ChatScrollIntentHandlers) {
            self.handlers = handlers
            document?.isBottomFollowingEnabled = handlers.isBottomFollowingEnabled
        }

        /// Called after every install, so it must converge when repeated.
        func attach(to document: any ChatMacScrollDocument) {
            if self.document !== document {
                self.document?.onReaderScroll = nil
                self.document = document
                document.onReaderScroll = { [weak self, weak document] top in
                    guard let self, let document else { return }
                    self.handlers.noteReaderScroll(from: top, in: document)
                }
            }
            document.isBottomFollowingEnabled = handlers.isBottomFollowingEnabled
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
        func pinToBottom() -> Bool {
            document?.scrollToBottom() ?? false
        }
    }
#endif
