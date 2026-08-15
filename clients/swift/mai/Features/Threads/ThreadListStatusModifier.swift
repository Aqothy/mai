import SwiftUI

struct ThreadListStatusModifier: ViewModifier {
    let store: ThreadStore
    /// Merged-list hosts override this so terminal rows count as content.
    var contentIsEmpty: Bool? = nil

    func body(content: Content) -> some View {
        content
            .overlay {
                if contentIsEmpty ?? store.isThreadListEmpty {
                    ThreadListEmptyStateView(store: store)
                }
            }
            .safeAreaInset(edge: .bottom) {
                ConnectionStatusView(store: store)
            }
    }
}
