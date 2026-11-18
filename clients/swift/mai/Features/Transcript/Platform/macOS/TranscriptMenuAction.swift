#if os(macOS)
    import AppKit

    /// Runs a menu item's closure: the menus the transcript builds for its
    /// rows (the fork menu) have no responder to send actions to. The item
    /// keeps it as its represented object, since a target is not retained.
    final class TranscriptMenuAction: NSObject {
        private let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
        }

        @objc func run(_ sender: Any?) {
            handler()
        }
    }

    extension NSMenu {
        /// The platform menu for a row's menu.
        convenience init(_ menu: TranscriptMenu) {
            self.init()
            for item in menu.items { addItem(Self.item(item)) }
        }

        private static func item(_ item: TranscriptMenu.Item) -> NSMenuItem {
            let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            if let image = item.systemImage {
                menuItem.image = NSImage(systemSymbolName: image, accessibilityDescription: nil)
            }
            if let handler = item.action {
                let action = TranscriptMenuAction(handler)
                menuItem.target = action
                menuItem.action = #selector(TranscriptMenuAction.run(_:))
                menuItem.representedObject = action
            }
            if !item.children.isEmpty {
                let submenu = NSMenu()
                for child in item.children { submenu.addItem(Self.item(child)) }
                menuItem.submenu = submenu
            }
            return menuItem
        }
    }
#endif
