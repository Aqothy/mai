import SwiftUI

struct ChatMarkdownMessageView: View {
    let messageID: String
    let source: String
    let presentation: ChatMarkdownPresentation

    var body: some View {
        ChatMarkdownMessageLifetimeView(
            messageID: messageID,
            source: source,
            presentation: presentation
        )
        .equatable()
        .id(messageID)
    }
}

/// Reads high-frequency text from the stable live-row model at the narrowest
/// possible SwiftUI boundary. Streaming intentionally stays plain for now so
/// no cumulative prefix is reparsed on every token update.
struct ChatStreamingMarkdownMessageView: View {
    let messageID: String
    let streamingText: ThreadStreamingText
    let presentation: ChatMarkdownPresentation

    var body: some View {
        ChatMarkdownMessageView(
            messageID: messageID,
            source: streamingText.text,
            presentation: presentation
        )
    }
}

/// Keeps stable timeline updates at a cheap equality check. Settled assistant
/// timeline rows normally use the selectable TextKit prose host; this remains
/// the package-free fallback for document-wide Markdown edge cases.
private struct ChatMarkdownMessageLifetimeView: Equatable, View {
    let messageID: String
    let source: String
    let presentation: ChatMarkdownPresentation

    nonisolated static func == (
        lhs: ChatMarkdownMessageLifetimeView,
        rhs: ChatMarkdownMessageLifetimeView
    ) -> Bool {
        lhs.messageID == rhs.messageID
            && lhs.source == rhs.source
            && lhs.presentation == rhs.presentation
    }

    var body: some View {
        Group {
            if presentation.isStreaming {
                Text(verbatim: source)
            } else {
                Text(
                    ChatMarkdownRenderCache.shared.attributedString(
                        messageID: messageID,
                        source: source
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ChatMarkdownContentStyle())
        #if DEBUG
            .overlay(alignment: .topTrailing) {
                if presentation.showsDiagnostics {
                    Text(
                        presentation.isStreaming
                            ? "plain stream · \(source.count.formatted()) chars"
                            : "native prose · \(source.count.formatted()) chars"
                    )
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: .capsule)
                    .accessibilityLabel("Markdown renderer diagnostics")
                }
            }
        #endif
    }
}
