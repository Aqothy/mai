#if os(macOS)
    import AppKit
    import SwiftUI

    /// Finds the `NSTableView` backing one specific SwiftUI `List`.
    ///
    /// The marker fills the List's background. Searching outward from that
    /// marker and requiring the table's visible clip view to contain the
    /// marker's center keeps the lookup scoped to the chat List, even when the
    /// same window contains another table such as the thread sidebar.
    struct ChatMacTableViewIntrospector: NSViewRepresentable {
        let onResolve: (NSTableView) -> Void

        func makeNSView(context: Context) -> FinderView {
            let view = FinderView()
            view.onResolve = onResolve
            return view
        }

        func updateNSView(_ nsView: FinderView, context: Context) {
            nsView.onResolve = onResolve
            nsView.resolveIfNeeded()
        }

        static func dismantleNSView(
            _ nsView: FinderView,
            coordinator: Void
        ) {
            nsView.onResolve = nil
        }

        final class FinderView: NSView {
            var onResolve: ((NSTableView) -> Void)? {
                didSet {
                    if let tableView {
                        onResolve?(tableView)
                    }
                }
            }

            private weak var tableView: NSTableView?

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToSuperview() {
                super.viewDidMoveToSuperview()
                resolveIfNeeded()
            }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                resolveIfNeeded()
            }

            override func layout() {
                super.layout()
                resolveIfNeeded()
            }

            func resolveIfNeeded() {
                guard tableView == nil, let window else { return }
                let markerCenter = convert(
                    NSPoint(x: bounds.midX, y: bounds.midY),
                    to: nil
                )

                var searchRoot = superview
                while let root = searchRoot {
                    if let match = Self.firstVisibleTable(
                        under: root,
                        containing: markerCenter,
                        in: window
                    ) {
                        tableView = match
                        onResolve?(match)
                        return
                    }
                    searchRoot = root.superview
                }
            }

            private static func firstVisibleTable(
                under root: NSView,
                containing pointInWindow: NSPoint,
                in window: NSWindow
            ) -> NSTableView? {
                if let table = root as? NSTableView,
                    table.window === window,
                    !table.isHiddenOrHasHiddenAncestor,
                    let clipView = table.enclosingScrollView?.contentView,
                    clipView.bounds.contains(
                        clipView.convert(pointInWindow, from: nil)
                    )
                {
                    return table
                }

                for subview in root.subviews {
                    if let match = firstVisibleTable(
                        under: subview,
                        containing: pointInWindow,
                        in: window
                    ) {
                        return match
                    }
                }
                return nil
            }
        }
    }
#endif
