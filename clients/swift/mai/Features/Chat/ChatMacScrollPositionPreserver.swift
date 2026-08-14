#if os(macOS)
    import AppKit

    /// Preserves the visible table row while SwiftUI prepends chat history.
    ///
    /// `List` initially estimates offscreen automatic row heights. Keep a
    /// visible anchor stable as those estimates are replaced, while allowing
    /// trackpad scrolling to continue between layout updates.
    final class ChatMacScrollPositionPreserver: NSObject {
        /// Ignore subpixel frame noise while still correcting a one-pixel
        /// movement on Retina displays.
        private static let minimumLayoutCorrection: CGFloat = 0.5

        private weak var tableView: NSTableView?
        private weak var scrollView: NSScrollView?
        private var snapshot: Snapshot?
        private var preservedAnchor: PreservedAnchor?
        private var isRestoring = false
        private var isApplyingLayoutAdjustment = false

        func attach(to tableView: NSTableView) {
            guard self.tableView !== tableView else { return }

            NotificationCenter.default.removeObserver(self)
            snapshot = nil
            preservedAnchor = nil
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
            }
        }

        /// Captures a visible row just before the model mutation that prepends
        /// `leadingRowCount` native table rows.
        func captureBeforePrepend(leadingRowCount: Int) {
            snapshot = nil
            preservedAnchor = nil
            guard leadingRowCount > 0, let tableView,
                let scrollView = tableView.enclosingScrollView
            else { return }

            tableView.layoutSubtreeIfNeeded()

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

            snapshot = Snapshot(
                expectedRowCount: tableView.numberOfRows + leadingRowCount,
                anchorRowAfterPrepend: anchorRow + leadingRowCount,
                anchorYBeforePrepend: anchorRect.minY,
                visibleYBeforePrepend: visibleRect.minY
            )
        }

        @objc
        private func tableFrameDidChange(_ notification: Notification) {
            guard notification.object as? NSTableView === tableView else {
                return
            }
            if snapshot == nil {
                compensateForAnchorMovementIfNeeded()
            }
            restoreCapturedPositionIfPossible()
        }

        @objc
        private func clipViewBoundsDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                clipView === scrollView?.contentView
            else { return }
            guard snapshot == nil, preservedAnchor != nil,
                !isApplyingLayoutAdjustment
            else { return }
            rebasePreservedAnchor(in: clipView.documentVisibleRect)
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
                let scrollView = tableView.enclosingScrollView,
                !isRestoring
            else { return }
            isRestoring = true
            defer { isRestoring = false }

            tableView.layoutSubtreeIfNeeded()
            guard tableView.numberOfRows >= snapshot.expectedRowCount,
                snapshot.anchorRowAfterPrepend < tableView.numberOfRows
            else { return }

            let anchorRect = tableView.rect(ofRow: snapshot.anchorRowAfterPrepend)
            guard !anchorRect.isEmpty else { return }

            let clipView = scrollView.contentView
            var proposedBounds = clipView.bounds
            proposedBounds.origin.y = snapshot.visibleYBeforePrepend
                + anchorRect.minY - snapshot.anchorYBeforePrepend
            let target = clipView.constrainBoundsRect(proposedBounds).origin
            preservedAnchor = PreservedAnchor(
                row: snapshot.anchorRowAfterPrepend,
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

        private struct Snapshot {
            let expectedRowCount: Int
            let anchorRowAfterPrepend: Int
            let anchorYBeforePrepend: CGFloat
            let visibleYBeforePrepend: CGFloat
        }

        private struct PreservedAnchor {
            let row: Int
            var lastAnchorY: CGFloat
        }
    }
#endif
