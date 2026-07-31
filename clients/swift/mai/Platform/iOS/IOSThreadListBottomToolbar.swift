#if os(iOS)
import SwiftUI

/// Places the searchable field and the New Chat button in the bottom toolbar
/// on iOS 26, where both receive the system glass treatment. Earlier systems
/// keep the search field in its default navigation-bar placement.
struct IOSThreadListBottomToolbar: ViewModifier {
    let newChat: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.toolbar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("New Chat", systemImage: "square.and.pencil", action: newChat)
                }
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button("New Chat", systemImage: "square.and.pencil", action: newChat)
                }
            }
        }
    }
}
#endif
