#if os(macOS)
    import AppKit

    /// Routes vertical trackpad gestures over a nested horizontal ScrollView
    /// to the chat List while leaving horizontal gestures with the nested view.
    final class ChatMacNestedScrollRouter {
        private weak var tableView: NSTableView?
        private var eventMonitor: Any?

        func attach(to tableView: NSTableView) {
            guard self.tableView !== tableView else { return }
            removeEventMonitor()
            self.tableView = tableView
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .scrollWheel
            ) { [weak self] event in
                let didRoute = self?.route(event) ?? false
                return didRoute ? nil : event
            }
        }

        isolated deinit {
            removeEventMonitor()
        }

        private func route(_ event: NSEvent) -> Bool {
            guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                let tableView,
                let outerScrollView = tableView.enclosingScrollView,
                event.window === outerScrollView.window,
                let window = event.window,
                let hitView = window.contentView?.hitTest(event.locationInWindow),
                outerScrollView.contentView.bounds.contains(
                    outerScrollView.contentView.convert(
                        event.locationInWindow,
                        from: nil
                    )
                ),
                let nestedScrollView = Self.nearestScrollView(from: hitView),
                nestedScrollView !== outerScrollView
            else { return false }

            outerScrollView.scrollWheel(with: event)
            return true
        }

        private func removeEventMonitor() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        private static func nearestScrollView(from view: NSView) -> NSScrollView? {
            var candidate: NSView? = view
            while let current = candidate {
                if let scrollView = current as? NSScrollView {
                    return scrollView
                }
                candidate = current.superview
            }
            return nil
        }
    }
#endif
