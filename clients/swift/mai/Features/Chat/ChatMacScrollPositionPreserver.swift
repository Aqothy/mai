#if os(macOS)
    import AppKit

    /// Tells the chat's scroll state what the reader did with the transcript:
    /// a trackpad or wheel scroll, Page Up, Page Down or Space, or reaching
    /// the end.
    ///
    /// A gesture scroll, its momentum included, is one AppKit live scroll of
    /// this scroll view, wherever the pointer goes; a mouse wheel notch or a
    /// key has no live scroll and is a scroll of its own.
    ///
    /// The document keeps the reading position itself, in the same pass that
    /// changes row geometry. This controller only separates the reader's
    /// intent from the clip moves layout makes, and lands the first rows on
    /// the transcript's end.
    @MainActor
    final class ChatMacScrollPositionPreserver: NSObject {
        private weak var document: (any ChatMacScrollDocument)?
        private weak var scrollView: NSScrollView?
        /// Held until a document exists to carry the alignment out.
        private var pendingInitialBottomAlignment: (() -> Void)?
        // AppKit owns this opaque token. All mutation is main-actor confined;
        // deinit only needs to unregister it from AppKit.
        nonisolated(unsafe) private var inputEventMonitor: Any?
        private var isDiscreteScrollFinishScheduled = false
        private var userScrollStartY: CGFloat?
        private var isLiveScrolling = false
        /// From the reader's live scroll's momentum starting until it ends.
        private var isCoasting = false
        /// Set by a move to the end while the reader's scroll coasts, until
        /// the momentum ends. It would carry the reader off the end the app
        /// just showed, and AppKit has no call that stops it; its events
        /// are not delivered.
        private var dropsMomentum = false
        private var handlers = ChatScrollIntentHandlers()

        func configure(_ handlers: ChatScrollIntentHandlers) {
            self.handlers = handlers
            document?.isBottomFollowingEnabled = handlers.isBottomFollowingEnabled
        }

        /// Called after every install, so it must converge when repeated.
        func attach(to document: any ChatMacScrollDocument) {
            if self.document !== document {
                NotificationCenter.default.removeObserver(self)
                removeInputEventMonitor()
                userScrollStartY = nil
                isLiveScrolling = false
                isCoasting = false
                dropsMomentum = false
                self.document = document
                scrollView = document.enclosingScrollView
                if let scrollView {
                    NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(willStartLiveScroll(_:)),
                        name: NSScrollView.willStartLiveScrollNotification,
                        object: scrollView
                    )
                    NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(didEndLiveScroll(_:)),
                        name: NSScrollView.didEndLiveScrollNotification,
                        object: scrollView
                    )
                    installInputEventMonitor()
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
            if isCoasting {
                dropsMomentum = true
                finishUserScroll()
            }
            return document?.scrollToBottom() ?? false
        }

        // MARK: Reader input

        @objc
        private func willStartLiveScroll(_ notification: Notification) {
            guard notification.object as? NSScrollView === scrollView else {
                return
            }
            isLiveScrolling = true
            document?.completeInitialBottomAlignment()
            beginUserScroll()
        }

        @objc
        private func didEndLiveScroll(_ notification: Notification) {
            guard notification.object as? NSScrollView === scrollView else {
                return
            }
            isLiveScrolling = false
            isCoasting = false
            dropsMomentum = false
            finishUserScroll()
        }

        private func installInputEventMonitor() {
            inputEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [
                    .keyDown,
                    .scrollWheel,
                ]
            ) { [weak self] event in
                switch event.type {
                case .keyDown:
                    self?.handleKeyDown(event)
                case .scrollWheel:
                    if self?.deliversScrollWheel(event) == false { return nil }
                default:
                    break
                }
                return event
            }
        }

        private func removeInputEventMonitor() {
            guard let inputEventMonitor else { return }
            NSEvent.removeMonitor(inputEventMonitor)
            self.inputEventMonitor = nil
        }

        private func handleKeyDown(_ event: NSEvent) {
            guard let scrollView, let document,
                event.window === scrollView.window,
                let responder = event.window?.firstResponder as? NSView,
                responder === document || responder.isDescendant(of: document)
            else { return }
            if let textView = responder as? NSTextView, textView.isEditable {
                return
            }

            switch event.keyCode {
            case 116: // Page Up
                handlers.noteKeyboardScrollIntent(false)
                beginUserScroll()
                scheduleDiscreteScrollFinish()
            case 121: // Page Down
                handlers.noteKeyboardScrollIntent(true)
                beginUserScroll()
                scheduleDiscreteScrollFinish()
            case 49: // Space / Shift-Space
                handlers.noteKeyboardScrollIntent(!event.modifierFlags.contains(.shift))
                beginUserScroll()
                scheduleDiscreteScrollFinish()
            default:
                break
            }
        }

        /// Notes the reader's scroll, and returns false for momentum the
        /// app's move to the end ended.
        private func deliversScrollWheel(_ event: NSEvent) -> Bool {
            guard let scrollView, event.window === scrollView.window else { return true }
            if !event.momentumPhase.isEmpty {
                // AppKit latches momentum to the scroll view its gesture
                // began in; while this one live-scrolls, it is this one's.
                guard isLiveScrolling else { return true }
                let ends =
                    event.momentumPhase.contains(.ended)
                    || event.momentumPhase.contains(.cancelled)
                if event.momentumPhase.contains(.began) {
                    isCoasting = true
                    dropsMomentum = false
                }
                if ends { isCoasting = false }
                guard dropsMomentum else { return true }
                // The last event lets the scroll view end its live scroll.
                if ends { dropsMomentum = false }
                return ends
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                // Content that can't scroll gets no live scroll to end it.
                if !isLiveScrolling { finishUserScroll() }
                return true
            }
            let point = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(point),
                abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
                event.scrollingDeltaY != 0
            else { return true }
            // A gesture's movement is the reader's even after a move to the
            // end finished their scroll; its live scroll's end finishes it.
            beginUserScroll()
            if event.phase.isEmpty {
                scheduleDiscreteScrollFinish()
            }
            return true
        }

        /// A mouse wheel notch or a key has no end event; the scroll it
        /// makes is over once the event that caused it is handled.
        private func scheduleDiscreteScrollFinish() {
            guard !isDiscreteScrollFinishScheduled else { return }
            isDiscreteScrollFinishScheduled = true
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.isDiscreteScrollFinishScheduled = false
                self.finishUserScroll()
            }
        }

        /// Safe to repeat: the live scroll's end can follow a finish the
        /// app's move to the end already made.
        private func finishUserScroll() {
            guard let startY = userScrollStartY else { return }
            userScrollStartY = nil
            document?.isReaderScrolling = false
            handlers.finishUserScroll(
                startY: startY,
                endY: scrollView?.contentView.documentVisibleRect.minY ?? startY,
                isNearBottom: document?.isNearBottom ?? false)
        }

        private func beginUserScroll() {
            guard let scrollView else { return }
            if userScrollStartY == nil {
                userScrollStartY = scrollView.contentView.documentVisibleRect.minY
            }
            document?.isReaderScrolling = true
            handlers.noteUserScrollActivity(true)
        }

        deinit {
            if let inputEventMonitor {
                NSEvent.removeMonitor(inputEventMonitor)
            }
            NotificationCenter.default.removeObserver(self)
        }
    }
#endif
