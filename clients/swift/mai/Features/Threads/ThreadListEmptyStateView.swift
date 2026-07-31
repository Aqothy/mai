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
        } else {
            // Any disconnected state with nothing to show: skeleton rows,
            // with the connection status pill reporting progress or offering
            // a retry below.
            ThreadListLoadingPlaceholderView()
        }
    }
}
