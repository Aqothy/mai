import SwiftUI

struct ThreadListEmptyStateView: View {
    let store: ThreadStore

    var body: some View {
        if store.connectionState == .connected {
            #if os(macOS)
                // Compact enough to sit comfortably in the narrow sidebar
                // column, where ContentUnavailableView's title feels outsized.
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 2)
                    Text("No Threads")
                        .font(.callout.weight(.semibold))
                    Text("Your conversations will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            #else
                ContentUnavailableView(
                    "No Threads",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Your conversations will appear here.")
                )
            #endif
        } else {
            // Any disconnected state with nothing to show: skeleton rows,
            // with the connection status pill reporting progress or offering
            // a retry below. macOS renders its skeleton inside the sidebar
            // List itself, where the title-bar safe area is respected.
            #if os(iOS)
                ThreadListLoadingPlaceholderView()
            #endif
        }
    }
}
