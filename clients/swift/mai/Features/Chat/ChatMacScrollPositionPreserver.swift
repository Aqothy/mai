#if os(macOS)
    import AppKit

    /// Preserves the visible native row while chat history is prepended or reflowed.
    ///
    /// `List` initially estimates offscreen automatic row heights. Keep a
    /// visible anchor stable as those estimates are replaced, while allowing
    /// trackpad scrolling to continue between layout updates.
    @MainActor
    final class ChatMacScrollPositionPreserver: NSObject {
        /// Ignore subpixel frame noise while still correcting a one-pixel
        /// movement on Retina displays.
        nonisolated private static let minimumLayoutCorrection: CGFloat = 0.5

        private weak var document: (any ChatMacScrollDocument)?
        private weak var scrollView: NSScrollView?
        private var snapshot: AnchorSnapshot?
        private var preservedAnchor: PreservedAnchor?
        private var isApplyingLayoutAdjustment = false
        private var isAligningInitialBottom = false
        private var initialBottomAlignmentCompletion: (() -> Void)?
        private var isUpdateScheduled = false
        private var shouldRebaseAnchor = false
        private var lastClipBounds: NSRect?
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
        }

        func attach(to document: any ChatMacScrollDocument) {
            guard self.document !== document else { return }

            NotificationCenter.default.removeObserver(self)
            removeInputEventMonitor()
            self.document?.setGeometryCommitHandler(nil)
            snapshot = nil
            preservedAnchor = nil
            shouldRebaseAnchor = false
            userScrollStartY = nil
            isMonitoringScrollWheel = false
            self.document = document
            scrollView = document.enclosingScrollView
            let commitsGeometry = document.setGeometryCommitHandler { [weak self] in
                // Virtual geometry is final at this boundary. Correct the clip
                // origin in the same transaction as row frames, without yielding.
                self?.processPendingUpdate(completesInitialAlignment: false)
            }
            if !commitsGeometry {
                document.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(documentFrameDidChange(_:)),
                    name: NSView.frameDidChangeNotification,
                    object: document
                )
            }
            if let scrollView {
                let clipView = scrollView.contentView
                lastClipBounds = clipView.bounds
                clipView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(clipViewBoundsDidChange(_:)),
                    name: NSView.boundsDidChangeNotification,
                    object: clipView
                )
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
            if isAligningInitialBottom {
                scheduleUpdate()
            }
        }

        /// Arms an initial and subsequent-layout bottom alignment without
        /// resolving a SwiftUI row identifier through the full List.
        func beginInitialBottomAlignment(
            completion: @escaping () -> Void
        ) {
            initialBottomAlignmentCompletion = completion
            isAligningInitialBottom = true
            scheduleUpdate()
        }

        /// Performs a constant-time native offset write. The SwiftUI proxy is
        /// retained only as a fallback during the short attach window.
        @discardableResult
        func pinToBottom() -> Bool {
            guard let scrollView, let document else { return false }
            let clipView = scrollView.contentView
            var proposedBounds = clipView.bounds
            proposedBounds.origin.y = Self.bottomOrigin(
                documentMinY: document.bounds.minY,
                documentMaxY: document.bounds.maxY,
                viewportHeight: proposedBounds.height,
                topInset: clipView.contentInsets.top,
                bottomInset: clipView.contentInsets.bottom
            )
            let target = clipView.constrainBoundsRect(proposedBounds).origin
            applyScrollPosition(target, in: scrollView)
            return true
        }

        nonisolated static func bottomOrigin(
            documentMinY: CGFloat,
            documentMaxY: CGFloat,
            viewportHeight: CGFloat,
            topInset: CGFloat,
            bottomInset: CGFloat
        ) -> CGFloat {
            max(
                documentMinY - topInset,
                documentMaxY - viewportHeight + bottomInset
            )
        }

        nonisolated static func shouldRestoreFollowingAfterUserScroll(
            startY: CGFloat?,
            endY: CGFloat?,
            isNearBottom: Bool
        ) -> Bool {
            guard isNearBottom else { return false }
            guard let startY, let endY else { return true }
            return endY >= startY - minimumLayoutCorrection
        }

        /// Captures a visible row just before the model mutation that prepends
        /// `leadingRowCount` native table rows.
        func captureBeforePrepend(leadingRowCount: Int) {
            guard leadingRowCount > 0 else { return }
            captureVisibleAnchor(
                rowOffsetAfterMutation: leadingRowCount,
                minimumRowCountAfterMutation: (document?.numberOfRows ?? 0)
                    + leadingRowCount
            )
        }

        /// Captures the first substantive visible row before a disclosure
        /// changes height. The disclosure is at or below that anchor, so its
        /// native table index remains stable while the row expands or folds.
        func captureBeforeContentExpansion() {
            captureVisibleAnchor(
                rowOffsetAfterMutation: 0,
                minimumRowCountAfterMutation: 0
            )
        }

        private func captureVisibleAnchor(
            rowOffsetAfterMutation: Int,
            minimumRowCountAfterMutation: Int
        ) {
            snapshot = nil
            preservedAnchor = nil
            shouldRebaseAnchor = false
            guard let document,
                let scrollView = document.enclosingScrollView
            else { return }

            let visibleRect = scrollView.contentView.documentVisibleRect
            let visibleRows = document.rows(in: visibleRect)
            guard visibleRows.location != NSNotFound, visibleRows.length > 0,
                let anchorRow = anchorRow(
                    in: visibleRows,
                    document: document
                )
            else { return }

            let anchorRect = document.rect(ofRow: anchorRow)
            guard !anchorRect.isEmpty else { return }

            snapshot = AnchorSnapshot(
                expectedRowCount: minimumRowCountAfterMutation,
                anchorRowAfterMutation: anchorRow + rowOffsetAfterMutation,
                stableID: document.stableIdentity(forRow: anchorRow),
                anchorYBeforePrepend: anchorRect.minY,
                visibleYBeforePrepend: visibleRect.minY
            )
        }

        @objc
        private func documentFrameDidChange(_ notification: Notification) {
            guard notification.object as? any ChatMacScrollDocument === document else {
                return
            }
            guard snapshot != nil || preservedAnchor != nil
                || isAligningInitialBottom || isBottomFollowingEnabled()
            else { return }
            scheduleUpdate()
        }

        @objc
        private func clipViewBoundsDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                clipView === scrollView?.contentView
            else { return }
            let previousBounds = lastClipBounds
            lastClipBounds = clipView.bounds
            guard snapshot == nil, !isApplyingLayoutAdjustment else { return }
            if isBottomFollowingEnabled() {
                preservedAnchor = nil
                shouldRebaseAnchor = false
                return
            }

            // During a gesture the user's native scroll position is the source
            // of truth. Rebase once when the gesture ends instead of creating
            // main-actor work at display cadence.
            if userScrollStartY != nil {
                shouldRebaseAnchor = true
                return
            }

            // AppKit may move the clip origin when its viewport is resized.
            // That movement is layout, not reader intent. Keep the previous
            // top position; the document-height observer then applies reflow
            // deltas relative to the same message anchor.
            if let previousBounds, previousBounds.size != clipView.bounds.size,
                let scrollView
            {
                var proposed = clipView.bounds
                proposed.origin.y = previousBounds.minY
                applyScrollPosition(clipView.constrainBoundsRect(proposed).origin, in: scrollView)
                lastClipBounds = clipView.bounds
            }

            // Track the row currently under the reader whenever native input
            // moves the viewport. A later width change can then compensate
            // for rewrapping above that row instead of changing what is being
            // read. Pagination uses its explicit pre-mutation snapshot.
            shouldRebaseAnchor = true
            scheduleUpdate()
        }

        @objc
        private func willStartLiveScroll(_ notification: Notification) {
            guard notification.object as? NSScrollView === scrollView else {
                return
            }
            completeInitialBottomAlignment()
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
            noteUserScrollActivity(false)
            if Self.shouldRestoreFollowingAfterUserScroll(
                startY: startY,
                endY: endY,
                isNearBottom: isNearBottom()
            ) {
                noteUserReachedEnd()
                preservedAnchor = nil
                shouldRebaseAnchor = false
            } else {
                shouldRebaseAnchor = true
                scheduleUpdate()
            }
        }

        private func beginUserScroll() {
            if userScrollStartY == nil {
                userScrollStartY = scrollView?.contentView.documentVisibleRect.minY
                preservedAnchor = nil
                shouldRebaseAnchor = false
            }
            noteUserScrollActivity(true)
        }

        private func isNearBottom(
            distance: CGFloat = ChatTimelineMetrics.nearBottomDistance
        ) -> Bool {
            guard let scrollView, let document else { return false }
            let clipView = scrollView.contentView
            return document.bounds.maxY + clipView.contentInsets.bottom
                - clipView.documentVisibleRect.maxY <= distance
        }

        /// Native documents post frame notifications during layout. Deferring
        /// rect reads and offset writes avoids reentrant layout and coalesces
        /// a burst of changes into one run-loop turn.
        private func scheduleUpdate() {
            guard !isUpdateScheduled else { return }
            isUpdateScheduled = true
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.isUpdateScheduled = false
                self.processPendingUpdate()
            }
        }

        private func processPendingUpdate(completesInitialAlignment: Bool = true) {
            if snapshot == nil {
                compensateForAnchorMovementIfNeeded()
            }
            restoreCapturedPositionIfPossible()

            if shouldRebaseAnchor, snapshot == nil,
                let visibleRect = scrollView?.contentView.documentVisibleRect
            {
                shouldRebaseAnchor = false
                rebasePreservedAnchor(in: visibleRect)
            }
            if isAligningInitialBottom, pinToBottom() {
                if completesInitialAlignment { completeInitialBottomAlignment() }
            } else if isBottomFollowingEnabled() {
                _ = pinToBottom()
            }
        }

        private func completeInitialBottomAlignment() {
            isAligningInitialBottom = false
            let completion = initialBottomAlignmentCompletion
            initialBottomAlignmentCompletion = nil
            completion?()
        }

        private func anchorRow(
            in visibleRows: NSRange,
            document: any ChatMacScrollDocument
        ) -> Int? {
            let rowRange = visibleRows.location..<NSMaxRange(visibleRows)
            let validRows = rowRange.filter { $0 < document.numberOfRows }
            guard let firstRow = validRows.first else { return nil }

            // The pagination marker is a one-point transparent List row. A
            // substantive row is a more reliable anchor, but retain a fallback
            // for unusually small content.
            return validRows.first(where: {
                document.rect(ofRow: $0).height
                    > ChatTimelineMetrics.historyMarkerHeight
            }) ?? firstRow
        }

        private func resolveAnchorRow(
            id: String?, fallback: Int, in document: any ChatMacScrollDocument
        ) -> Int? {
            if let id { return document.row(forStableIdentity: id) }
            return fallback >= 0 && fallback < document.numberOfRows ? fallback : nil
        }

        private func restoreCapturedPositionIfPossible() {
            guard let snapshot, let document,
                let scrollView = document.enclosingScrollView
            else { return }

            guard document.numberOfRows >= snapshot.expectedRowCount,
                let row = resolveAnchorRow(
                    id: snapshot.stableID, fallback: snapshot.anchorRowAfterMutation, in: document),
                row < document.numberOfRows
            else { return }

            let anchorRect = document.rect(ofRow: row)
            guard !anchorRect.isEmpty else { return }

            let clipView = scrollView.contentView
            var proposedBounds = clipView.bounds
            proposedBounds.origin.y = snapshot.visibleYBeforePrepend
                + anchorRect.minY - snapshot.anchorYBeforePrepend
            let target = clipView.constrainBoundsRect(proposedBounds).origin
            preservedAnchor = PreservedAnchor(
                row: row,
                stableID: snapshot.stableID,
                lastAnchorY: anchorRect.minY,
                lastVisibleY: target.y
            )
            self.snapshot = nil
            applyScrollPosition(target, in: scrollView)
        }

        /// Keep the reader's offset within the anchor. AppKit may already have
        /// moved the clip for these same row-height changes, so adding the delta
        /// to its current origin would apply the layout correction twice.
        /// User gestures discard this anchor and rebase it when scrolling ends.
        private func compensateForAnchorMovementIfNeeded() {
            guard var preservedAnchor, let document,
                let scrollView = document.enclosingScrollView,
                !isApplyingLayoutAdjustment
            else { return }

            guard
                let row = resolveAnchorRow(
                    id: preservedAnchor.stableID, fallback: preservedAnchor.row, in: document),
                row < document.numberOfRows
            else {
                self.preservedAnchor = nil
                rebasePreservedAnchor(in: scrollView.contentView.documentVisibleRect)
                return
            }
            let anchorY = document.rect(ofRow: row).minY
            let delta = anchorY - preservedAnchor.lastAnchorY
            guard abs(delta) >= Self.minimumLayoutCorrection else { return }
            let clipView = scrollView.contentView
            var proposedBounds = clipView.bounds
            proposedBounds.origin.y = preservedAnchor.lastVisibleY + delta
            let target = clipView.constrainBoundsRect(proposedBounds).origin
            preservedAnchor.lastAnchorY = anchorY
            preservedAnchor.lastVisibleY = target.y
            self.preservedAnchor = preservedAnchor
            applyScrollPosition(target, in: scrollView)
        }

        /// Follow the user's current viewport so later height changes below it
        /// cannot move the viewport merely because the original anchor is now
        /// offscreen.
        private func rebasePreservedAnchor(in visibleRect: NSRect) {
            guard let document else { return }
            let visibleRows = document.rows(in: visibleRect)
            guard visibleRows.location != NSNotFound, visibleRows.length > 0,
                let row = anchorRow(in: visibleRows, document: document)
            else { return }
            let rect = document.rect(ofRow: row)
            guard !rect.isEmpty else { return }
            preservedAnchor = PreservedAnchor(
                row: row,
                stableID: document.stableIdentity(forRow: row),
                lastAnchorY: rect.minY,
                lastVisibleY: visibleRect.minY
            )
        }

        private func applyScrollPosition(
            _ position: NSPoint,
            in scrollView: NSScrollView
        ) {
            isApplyingLayoutAdjustment = true
            defer { isApplyingLayoutAdjustment = false }
            let clipView = scrollView.contentView
            clipView.scroll(to: position)
            scrollView.reflectScrolledClipView(clipView)
        }

        private struct AnchorSnapshot {
            let expectedRowCount: Int
            let anchorRowAfterMutation: Int
            let stableID: String?
            let anchorYBeforePrepend: CGFloat
            let visibleYBeforePrepend: CGFloat
        }

        private struct PreservedAnchor {
            let row: Int
            let stableID: String?
            var lastAnchorY: CGFloat
            var lastVisibleY: CGFloat
        }

        deinit {
            if let inputEventMonitor {
                NSEvent.removeMonitor(inputEventMonitor)
            }
            NotificationCenter.default.removeObserver(self)
        }
    }
#endif
