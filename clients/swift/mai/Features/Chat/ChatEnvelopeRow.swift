import SwiftUI

/// What another agent, or maiD, said to this chat's agent: a message, the
/// reply to one it sent, or a notice. Shown as said, with who said it.
struct ChatEnvelopeRow: View {
    let item: ChatItem

    var body: some View {
        if let envelope = item.entry.envelope {
            VStack(alignment: .leading, spacing: 6) {
                Label(title(envelope), systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let body = envelope.body, !body.isEmpty {
                    Text(body)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    private func title(_ envelope: Envelope) -> String {
        let sender = envelope.from.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "another agent")
        switch item.entry.envelopeKind {
        case .reply: return String(localized: "Reply from \(sender)")
        case .notice: return String(localized: "Notice")
        default: return String(localized: "From \(sender)")
        }
    }

    private var systemImage: String {
        switch item.entry.envelopeKind {
        case .reply: "arrowshape.turn.up.left"
        case .notice: "info.circle"
        default: "bubble.left.and.text.bubble.right"
        }
    }
}
