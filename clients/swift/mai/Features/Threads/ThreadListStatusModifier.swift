import SwiftUI

struct ThreadListStatusModifier: ViewModifier {
    let store: ThreadStore

    func body(content: Content) -> some View {
        content
            .overlay {
                if store.isThreadListEmpty {
                    ThreadListEmptyStateView(store: store)
                }
            }
            .safeAreaInset(edge: .bottom) {
                ConnectionStatusView(store: store)
            }
    }
}
