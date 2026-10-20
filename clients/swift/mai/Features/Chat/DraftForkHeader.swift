import SwiftUI

/// Heads a new chat that forks another: the agent gets the earlier
/// conversation as text with the first message, since it can't fork its own
/// sessions.
struct DraftForkHeader: View {
    let sourceTitle: String
    let discard: () -> Void

    var body: some View {
        VStack {
            Text("Continue “\(sourceTitle)”")
                .font(.largeTitle)
                .multilineTextAlignment(.center)
                .accessibilityHeading(.h1)

            Text("The earlier conversation goes to the agent with your first message.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Start Fresh Instead", systemImage: "xmark", action: discard)
                .buttonStyle(.bordered)
        }
    }
}

#if DEBUG
    #Preview("Fork Draft Header") {
        DraftForkHeader(sourceTitle: "Fix the flaky test", discard: {})
            .padding()
    }
#endif
