import SwiftUI

struct ThreadListStatusModifier: ViewModifier {
    let store: ThreadStore
    /// Project-grouped hosts override this so saved empty folders count as content.
    var contentIsEmpty: Bool?

    func body(content: Content) -> some View {
        content
            .overlay {
                if contentIsEmpty ?? store.isThreadListEmpty {
                    // An empty list means no chats only once maiD sent it.
                    if store.connectionState == .connected {
                        ThreadListEmptyStateView()
                    } else if let failure = store.connectionFailure {
                        ThreadListConnectionFailureView(failure: failure)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                ConnectionStatusView(store: store)
            }
    }
}
