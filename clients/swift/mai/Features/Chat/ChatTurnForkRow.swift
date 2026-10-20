import SwiftUI

/// Forks the chat at a settled turn: everything through it, or everything
/// before it with its prompt back in the composer to edit. The source chat
/// stays as it is.
struct ChatTurnForkRow: View {
    let fork: ChatTurnFork

    @Environment(\.chatFork) private var chatFork

    var body: some View {
        if let chatFork {
            Menu {
                Button("Fork from Here", systemImage: "arrow.triangle.branch") {
                    chatFork(.through(turnID: fork.turnID))
                }
                if let prompt = fork.prompt {
                    Button("Edit Prompt in New Chat", systemImage: "pencil") {
                        chatFork(.before(turnID: fork.turnID), editing: prompt)
                    }
                }
            } label: {
                Label("Fork", systemImage: "arrow.triangle.branch")
                    .labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 6)
            .accessibilityLabel("Fork from this turn")
        }
    }
}
