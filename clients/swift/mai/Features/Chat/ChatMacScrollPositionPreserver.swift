#if os(macOS)
    import AppKit

    /// Tells the chat's scroll state what the reader did with the transcript:
    /// a trackpad or wheel scroll, Page Up, Page Down or Space, or reaching
    /// the end.
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
        private var isMonitoringScrollWheel = false
        private var isDiscreteScrollFinishScheduled = false
        private var userScrollStartY: CGFloat?
        private var isBottomFollowingEnabled: () -> Bool = { false }
        private var noteUserScrollActivity: (Bool) -> Void = { _ in }
        private var noteUserReachedEnd: () -> Void = {}
        private var noteKeyboardScrollIntent: (Bool) -> Void = { _ in }

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
        func attach(to document: any ChatMacScrollDocument) {
            if self.document !== document {
                NotificationCenter.default.removeObserver(self)
                removeInputEventMonitor()
                userScrollStartY = nil
                isMonitoringScrollWheel = false
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
        func pinToBottom() -> Bool {
            document?.scrollToBottom() ?? false
        }

        // MARK: Reader input

        @objc
        private func willStartLiveScroll(_ notification: Notification) {
            guard notification.object as? NSScrollView === scrollView else {
                return
            }
            document?.completeInitialBottomAlignment()
            beginUserScroll()
        }

        @objc
        private func didEndLiveScroll(_ notification: Notification) {
            guard notification.object as? NSScrollView === scrollView else {
                return
            }
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
                    self?.handleScrollWheel(event)
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
                noteKeyboardScrollIntent(false)
                beginUserScroll()
                scheduleDiscreteScrollFinish()
            case 121: // Page Down
                noteKeyboardScrollIntent(true)
                beginUserScroll()
                scheduleDiscreteScrollFinish()
            case 49: // Space / Shift-Space
                noteKeyboardScrollIntent(!event.modifierFlags.contains(.shift))
                beginUserScroll()
                scheduleDiscreteScrollFinish()
            default:
                break
            }
        }

        private func handleScrollWheel(_ event: NSEvent) {
            guard let scrollView, event.window === scrollView.window else {
                return
            }
            let point = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(point) else { return }

            if event.phase == .ended || event.phase == .cancelled {
                guard isMonitoringScrollWheel else { return }
                isMonitoringScrollWheel = false
                finishUserScroll()
                return
            }

            let isVertical = abs(event.scrollingDeltaY)
                >= abs(event.scrollingDeltaX)
                && event.scrollingDeltaY != 0
            guard isVertical else { return }

            beginUserScroll()
            if event.phase == .began || event.phase == .changed
                || event.phase == .mayBegin
            {
                isMonitoringScrollWheel = true
            } else {
                scheduleDiscreteScrollFinish()
            }
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

        private func finishUserScroll() {
            let startY = userScrollStartY
            let endY = scrollView?.contentView.documentVisibleRect.minY
            userScrollStartY = nil
            document?.isReaderScrolling = false
            noteUserScrollActivity(false)
            if ChatScrollFollowPolicy.shouldRestoreFollowingAfterUserScroll(
                startY: startY,
                endY: endY,
                isNearBottom: document?.isNearBottom ?? false
            ) {
                noteUserReachedEnd()
            }
        }

        private func beginUserScroll() {
            if userScrollStartY == nil {
                userScrollStartY = scrollView?.contentView.documentVisibleRect.minY
            }
            document?.isReaderScrolling = true
            noteUserScrollActivity(true)
        }

        deinit {
            if let inputEventMonitor {
                NSEvent.removeMonitor(inputEventMonitor)
            }
            NotificationCenter.default.removeObserver(self)
        }
    }
#endif
