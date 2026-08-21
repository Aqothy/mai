#if os(macOS)
    import AppKit

    /// Preserves the visible table row while SwiftUI prepends chat history.
    ///
    /// `List` initially estimates offscreen automatic row heights. Keep a
    /// visible anchor stable as those estimates are replaced, while allowing
    /// trackpad scrolling to continue between layout updates.
    @MainActor
    final class ChatMacScrollPositionPreserver: NSObject {
        /// Ignore subpixel frame noise while still correcting a one-pixel
        /// movement on Retina displays.
        nonisolated private static let minimumLayoutCorrection: CGFloat = 0.5

        private weak var tableView: NSTableView?
        private weak var scrollView: NSScrollView?
        private var snapshot: AnchorSnapshot?
        private var preservedAnchor: PreservedAnchor?
        private var isApplyingLayoutAdjustment = false
        private var isAligningInitialBottom = false
        private var initialBottomAlignmentCompletion: (() -> Void)?
        private var isUpdateScheduled = false
        private var shouldRebaseAnchor = false
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

        func attach(to tableView: NSTableView) {
            guard self.tableView !== tableView else { return }

            NotificationCenter.default.removeObserver(self)
            removeInputEventMonitor()
            snapshot = nil
            preservedAnchor = nil
            shouldRebaseAnchor = false
            userScrollStartY = nil
            isMonitoringScrollWheel = false
            self.tableView = tableView
            scrollView = tableView.enclosingScrollView
            tableView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(tableFrameDidChange(_:)),
                name: NSView.frameDidChangeNotification,
                object: tableView
            )
            if let scrollView {
                let clipView = scrollView.contentView
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
            guard let scrollView, let tableView else { return false }
            let clipView = scrollView.contentView
            var proposedBounds = clipView.bounds
            proposedBounds.origin.y = Self.bottomOrigin(
                documentMinY: tableView.bounds.minY,
                documentMaxY: tableView.bounds.maxY,
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
                minimumRowCountAfterMutation: (tableView?.numberOfRows ?? 0)
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
            guard let tableView,
                let scrollView = tableView.enclosingScrollView
            else { return }

            let visibleRect = scrollView.contentView.documentVisibleRect
            let visibleRows = tableView.rows(in: visibleRect)
            guard visibleRows.location != NSNotFound, visibleRows.length > 0,
                let anchorRow = anchorRow(
                    in: visibleRows,
                    tableView: tableView
                )
            else { return }

            let anchorRect = tableView.rect(ofRow: anchorRow)
            guard !anchorRect.isEmpty else { return }

            snapshot = AnchorSnapshot(
                expectedRowCount: minimumRowCountAfterMutation,
                anchorRowAfterMutation: anchorRow + rowOffsetAfterMutation,
                anchorYBeforePrepend: anchorRect.minY,
                visibleYBeforePrepend: visibleRect.minY
            )
        }

        @objc
        private func tableFrameDidChange(_ notification: Notification) {
            guard notification.object as? NSTableView === tableView else {
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
            isAligningInitialBottom = false
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
            guard let scrollView, let tableView,
                event.window === scrollView.window,
                let responder = event.window?.firstResponder as? NSView,
                responder === tableView || responder.isDescendant(of: tableView)
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
            guard let scrollView, let tableView else { return false }
            let clipView = scrollView.contentView
            return tableView.bounds.maxY + clipView.contentInsets.bottom
                - clipView.documentVisibleRect.maxY <= distance
        }

        /// NSTableView posts frame notifications from inside its delegate and
        /// layout work. Deferring all rect reads and offset writes avoids a
        /// reentrant table operation and coalesces a burst to one run-loop turn.
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

        private func processPendingUpdate() {
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
                isAligningInitialBottom = false
                let completion = initialBottomAlignmentCompletion
                initialBottomAlignmentCompletion = nil
                completion?()
            } else if isBottomFollowingEnabled() {
                _ = pinToBottom()
            }
        }

        private func anchorRow(
            in visibleRows: NSRange,
            tableView: NSTableView
        ) -> Int? {
            let rowRange = visibleRows.location..<NSMaxRange(visibleRows)
            let validRows = rowRange.filter { $0 < tableView.numberOfRows }
            guard let firstRow = validRows.first else { return nil }

            // The pagination marker is a one-point transparent List row. A
            // substantive row is a more reliable anchor, but retain a fallback
            // for unusually small content.
            return validRows.first(where: {
                tableView.rect(ofRow: $0).height
                    > ChatTimelineMetrics.historyMarkerHeight
            }) ?? firstRow
        }

        private func restoreCapturedPositionIfPossible() {
            guard let snapshot, let tableView,
                let scrollView = tableView.enclosingScrollView
            else { return }

            guard tableView.numberOfRows >= snapshot.expectedRowCount,
                snapshot.anchorRowAfterMutation < tableView.numberOfRows
            else { return }

            let anchorRect = tableView.rect(ofRow: snapshot.anchorRowAfterMutation)
            guard !anchorRect.isEmpty else { return }

            let clipView = scrollView.contentView
            var proposedBounds = clipView.bounds
            proposedBounds.origin.y = snapshot.visibleYBeforePrepend
                + anchorRect.minY - snapshot.anchorYBeforePrepend
            let target = clipView.constrainBoundsRect(proposedBounds).origin
            preservedAnchor = PreservedAnchor(
                row: snapshot.anchorRowAfterMutation,
                lastAnchorY: anchorRect.minY
            )
            self.snapshot = nil
            applyScrollPosition(target, in: scrollView)
        }

        /// Adjust by exactly the layout-induced anchor delta. The clip view's
        /// current position already includes any intervening trackpad motion,
        /// so adding the delta preserves both the visible content and momentum.
        private func compensateForAnchorMovementIfNeeded() {
            guard var preservedAnchor, let tableView,
                let scrollView = tableView.enclosingScrollView,
                preservedAnchor.row < tableView.numberOfRows,
                !isApplyingLayoutAdjustment
            else { return }

            let anchorY = tableView.rect(ofRow: preservedAnchor.row).minY
            let delta = anchorY - preservedAnchor.lastAnchorY
            guard abs(delta) >= Self.minimumLayoutCorrection else { return }
            preservedAnchor.lastAnchorY = anchorY
            self.preservedAnchor = preservedAnchor

            let clipView = scrollView.contentView
            var proposedBounds = clipView.bounds
            proposedBounds.origin.y += delta
            let target = clipView.constrainBoundsRect(proposedBounds).origin
            applyScrollPosition(target, in: scrollView)
        }

        /// Follow the user's current viewport so later height changes below it
        /// cannot move the viewport merely because the original anchor is now
        /// offscreen.
        private func rebasePreservedAnchor(in visibleRect: NSRect) {
            guard let tableView else { return }
            let visibleRows = tableView.rows(in: visibleRect)
            guard visibleRows.location != NSNotFound, visibleRows.length > 0,
                let row = anchorRow(in: visibleRows, tableView: tableView)
            else { return }
            let rect = tableView.rect(ofRow: row)
            guard !rect.isEmpty else { return }
            preservedAnchor = PreservedAnchor(
                row: row,
                lastAnchorY: rect.minY
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
            let anchorYBeforePrepend: CGFloat
            let visibleYBeforePrepend: CGFloat
        }

        private struct PreservedAnchor {
            let row: Int
            var lastAnchorY: CGFloat
        }

        deinit {
            if let inputEventMonitor {
                NSEvent.removeMonitor(inputEventMonitor)
            }
            NotificationCenter.default.removeObserver(self)
        }
    }
#endif
