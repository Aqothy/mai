#if os(iOS)
import SwiftUI

/// Places the searchable field and the create buttons in the bottom toolbar
/// on iOS 26, where all receive the system glass treatment. New Chat and
/// New Terminal sit together as one grouped pair, each a single tap.
/// Earlier systems keep the search field in its default navigation-bar
/// placement.
struct IOSThreadListBottomToolbar: ViewModifier {
    let newChat: () -> Void
    let newTerminal: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.toolbar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItemGroup(placement: .bottomBar) {
                    newButtons
                }
            }
        } else {
            content.toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    newButtons
                }
            }
        }
    }

    @ViewBuilder
    private var newButtons: some View {
        Button("New Terminal", systemImage: "terminal", action: newTerminal)
        Button("New Chat", systemImage: "square.and.pencil", action: newChat)
    }
}
#endif
