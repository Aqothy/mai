import SwiftUI

/// The conversation an agent was handed as text — a fork's, or what it
/// missed while other agents worked — folded until the user opens it.
/// Snapshots cut long text; the whole of it loads on demand.
struct ChatHandoffRow: View {
    let item: ChatItem
    let threadID: String
    let store: ThreadStore

    @State private var isExpanded = false
    @State private var text: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Label(title, systemImage: "arrow.triangle.branch")
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)

            if isExpanded {
                if let text {
                    ScrollView {
                        Text(text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 320)
                    .padding(12)
                    .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .task(id: isExpanded) {
            guard isExpanded, text == nil else { return }
            await loadText()
        }
    }

    private var title: String {
        if let covers = item.entry.envelope?.covers, !covers.isEmpty {
            return String(localized: "Caught up on \(covers) of this chat")
        }
        return String(localized: "Continued from an earlier conversation")
    }

    private func loadText() async {
        errorMessage = nil
        guard item.detailAvailable else {
            text = item.entry.envelope?.body ?? ""
            return
        }
        do {
            let entry = try await store.entryDetail(threadID: threadID, item: item)
            text = entry.envelope?.body ?? ""
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
