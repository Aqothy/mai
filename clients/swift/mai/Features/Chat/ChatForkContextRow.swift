import SwiftUI

/// The earlier conversation a fork handed its agent as text, folded until
/// the user opens it. Snapshots leave the text out; it loads on demand.
struct ChatForkContextRow: View {
    let item: Item
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
                    Label("Continued from an earlier conversation", systemImage: "arrow.triangle.branch")
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

    private func loadText() async {
        errorMessage = nil
        do {
            let detail = try await store.itemDetail(threadID: threadID, item: item)
            text = (detail.payload?.value as? [String: Any])?["text"] as? String ?? ""
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
