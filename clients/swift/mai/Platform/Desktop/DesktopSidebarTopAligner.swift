#if os(macOS)
    import AppKit

    /// Keeps selection restoration from leaving a newly leading sidebar row
    /// partially clipped. The request stays active until two native layout
    /// turns pass without another table or viewport change.
    @MainActor
    final class DesktopSidebarTopAligner: NSObject {
        private weak var tableView: NSTableView?
        private weak var scrollView: NSScrollView?
        private var isAlignmentRequested = false
        private var isApplyingAlignment = false
        private var isUpdateScheduled = false
        private var changeGeneration = 0
        private var quietPassCount = 0

        func attach(to tableView: NSTableView) {
            guard self.tableView !== tableView else { return }
            NotificationCenter.default.removeObserver(self)
            self.tableView = tableView
            scrollView = tableView.enclosingScrollView

            tableView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(nativeLayoutDidChange(_:)),
                name: NSView.frameDidChangeNotification,
                object: tableView
            )
            if let clipView = scrollView?.contentView {
                clipView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(nativeLayoutDidChange(_:)),
                    name: NSView.boundsDidChangeNotification,
                    object: clipView
                )
            }
            scheduleUpdate()
        }

        func requestTopAlignment() {
            isAlignmentRequested = true
            noteChange()
        }

        @objc
        private func nativeLayoutDidChange(_ notification: Notification) {
            guard isAlignmentRequested, !isApplyingAlignment else { return }
            noteChange()
        }

        private func noteChange() {
            changeGeneration &+= 1
            quietPassCount = 0
            scheduleUpdate()
        }

        private func scheduleUpdate() {
            guard isAlignmentRequested, tableView != nil,
                !isUpdateScheduled
            else { return }
            isUpdateScheduled = true
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.isUpdateScheduled = false
                self.applyTopAlignment()
            }
        }

        private func applyTopAlignment() {
            guard let tableView, let scrollView else { return }
            let generation = changeGeneration
            let clipView = scrollView.contentView
            var proposedBounds = clipView.bounds
            proposedBounds.origin.y = tableView.bounds.minY
                - clipView.contentInsets.top

            isApplyingAlignment = true
            clipView.scroll(
                to: clipView.constrainBoundsRect(proposedBounds).origin
            )
            scrollView.reflectScrolledClipView(clipView)
            isApplyingAlignment = false

            if generation == changeGeneration {
                quietPassCount += 1
            } else {
                quietPassCount = 0
            }
            if quietPassCount >= 2 {
                isAlignmentRequested = false
            } else {
                scheduleUpdate()
            }
        }
    }
#endif
