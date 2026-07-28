import SwiftUI

struct ThreadListStatusModifier: ViewModifier {
    let store: ThreadStore

    func body(content: Content) -> some View {
        content
            .overlay {
                if store.threads.isEmpty {
                    ThreadListEmptyStateView(store: store)
                }
            }
            .safeAreaInset(edge: .bottom) {
                ConnectionStatusView(store: store)
            }
    }
}
