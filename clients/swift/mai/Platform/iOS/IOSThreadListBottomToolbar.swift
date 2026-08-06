#if os(iOS)
import SwiftUI

/// Places the searchable field and the create menu in the bottom toolbar on
/// iOS 26, where both receive the system glass treatment. Earlier systems
/// keep the search field in its default navigation-bar placement.
struct IOSThreadListBottomToolbar: ViewModifier {
    let newChat: () -> Void
    let newTerminal: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.toolbar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    NewThreadMenu(newChat: newChat, newTerminal: newTerminal)
                }
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .bottomBar) {
                    NewThreadMenu(newChat: newChat, newTerminal: newTerminal)
                }
            }
        }
    }
}

/// The primary create control: a menu offering both thread kinds.
private struct NewThreadMenu: View {
    let newChat: () -> Void
    let newTerminal: () -> Void

    var body: some View {
        Menu("New", systemImage: "square.and.pencil") {
            Button("New Chat", systemImage: "square.and.pencil", action: newChat)
            Button("New Terminal", systemImage: "terminal", action: newTerminal)
        }
        .accessibilityLabel("New thread")
    }
}
#endif
