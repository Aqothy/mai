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
/// possible SwiftUI boundary. Live source stays plain so token updates never
/// trigger Markdown parsing or syntax highlighting.
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

/// Keeps stable timeline updates at a cheap equality check. Settled plans are
/// process-cached so List remounts don't parse unchanged Markdown again.
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
                ChatMarkdownRichContentView(
                    plan: ChatMarkdownRenderCache.shared.plan(
                        messageID: messageID,
                        source: source
                    ),
                    allowsHighlighting: true
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
                            : "native rich · \(source.count.formatted()) chars"
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
