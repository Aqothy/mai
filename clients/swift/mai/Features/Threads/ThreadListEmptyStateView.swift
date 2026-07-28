import SwiftUI

struct ThreadListEmptyStateView: View {
    let store: ThreadStore

    var body: some View {
        if store.connectionState == .connected {
            ContentUnavailableView(
                "No Threads",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Your conversations will appear here.")
            )
        } else if store.automaticReconnectsExhausted {
            ContentUnavailableView {
                Label("maiD Unavailable", systemImage: "network.slash")
            } description: {
                Text(store.errorMessage ?? "Could not connect to the server.")
            } actions: {
                Button("Retry", action: store.retry)
            }
        } else {
            ReconnectOverlayView(store: store)
        }
    }
}
