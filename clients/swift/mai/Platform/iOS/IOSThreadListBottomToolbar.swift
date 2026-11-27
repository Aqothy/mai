#if os(iOS)
import SwiftUI

/// Places the searchable field and New Chat button in the bottom toolbar on
/// iOS 26. Earlier systems keep the search field in its default navigation-bar
/// placement.
struct IOSThreadListBottomToolbar: ViewModifier {
    let newChat: () -> Void

    func body(content: Content) -> some View {
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
                    chatButton
                }
            }
        } else {
            content.toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    chatButton
                }
            }
        }
    }
}

#endif
