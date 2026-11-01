import SwiftUI

/// Heads a new chat that continues another; the fork is made when its first
/// message is sent.
struct DraftForkHeader: View {
    let fork: ForkDraft
    let discard: () -> Void

    var body: some View {
        VStack {
            Text(fork.throughTurnID == nil ? "Start “\(fork.sourceTitle)” over" : "Continue “\(fork.sourceTitle)”")
                .font(.largeTitle)
                .multilineTextAlignment(.center)
                .accessibilityHeading(.h1)

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Start Fresh Instead", systemImage: "xmark", action: discard)
                .buttonStyle(.bordered)
        }
    }

    private var subtitle: String {
        if fork.throughTurnID == nil {
            return "A new chat in the same folders. Nothing is made until you send."
        }
        if fork.native {
            return "The agent picks up its own conversation where you forked it. Nothing is made until you send."
        }
        return "The conversation so far is in your message below: edit it, add to it, and send. Nothing is made until you send."
    }
}

#if DEBUG
    #Preview("Fork Draft Header") {
        DraftForkHeader(
            fork: ForkDraft(
                sourceThreadID: "chat",
                sourceTitle: "Fix the flaky test",
                throughTurnID: "turn",
                native: false,
                agentID: "claude-code",
                cwd: "/tmp/project",
                additionalDirectories: []
            ),
            discard: {}
        )
        .padding()
    }
#endif
