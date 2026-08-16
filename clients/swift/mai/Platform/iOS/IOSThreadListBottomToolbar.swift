import SwiftUI

/// Places the searchable field and create buttons in the bottom toolbar.
/// On iOS 26, fixed toolbar spacing gives New Chat and New Terminal separate
/// circular glass backgrounds. Earlier systems keep the search field in its
/// default navigation-bar placement.
struct IOSThreadListBottomToolbar: ViewModifier {
    let newChat: () -> Void
    let newTerminal: () -> Void

    func body(content: Content) -> some View {
        let terminalButton = Button(
            "New Terminal",
            systemImage: "terminal",
            action: newTerminal
        )
        let chatButton = Button(
            "New Chat",
            systemImage: "square.and.pencil",
            action: newChat
        )

        if #available(iOS 26.0, *) {
            content.toolbar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    terminalButton
                }
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    chatButton
                }
            }
        } else {
            content.toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    terminalButton
                    chatButton
                }
            }
        }
    }
}
