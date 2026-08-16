import SwiftUI

struct ThreadListEmptyStateView: View {
    var body: some View {
        ContentUnavailableView(
            "No Threads",
            systemImage: "bubble.left.and.bubble.right",
            description: Text("Your conversations will appear here.")
        )
    }
}
