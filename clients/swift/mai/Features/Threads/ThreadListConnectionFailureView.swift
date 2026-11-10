import SwiftUI

struct ThreadListConnectionFailureView: View {
    let failure: String

    var body: some View {
        ContentUnavailableView(
            "Can’t Reach maiD",
            systemImage: "network.slash",
            description: Text(failure)
        )
    }
}
