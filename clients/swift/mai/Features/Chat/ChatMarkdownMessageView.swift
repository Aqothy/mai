import SwiftUI

struct ChatMarkdownMessageView: View {
    let messageID: String
    let source: String
    let presentation: ChatMarkdownPresentation
    let textLayoutStore: ChatTextLayoutStore

    var body: some View {
        Group {
            if presentation.isStreaming {
                ChatStreamingMarkdownContentView(
                    messageID: messageID,
                    source: source,
                    // Production supplies a monotonic revision below. This
                    // value path exists for previews and deterministic labs,
                    // whose streams are append-only between replacements.
                    updateID: source.utf8.count,
                    sourceIsAppendOnly: false,
                    presentation: presentation,
                    textLayoutStore: textLayoutStore
                )
            } else {
                ChatMarkdownMessageLifetimeView(
                    messageID: messageID,
                    source: source,
                    presentation: presentation,
                    textLayoutStore: textLayoutStore
                )
                .equatable()
            }
        }
        .id(messageID)
    }
}

/// Reads high-frequency text at the narrowest SwiftUI boundary. Parsing is
/// serialized off the main actor; stable blocks remain equatable while the
/// active tail keeps updating, including during user-driven scrolling.
struct ChatStreamingMarkdownMessageView: View {
    let messageID: String
    let streamingText: ThreadStreamingText
    let presentation: ChatMarkdownPresentation
    let textLayoutStore: ChatTextLayoutStore

    var body: some View {
        ChatStreamingMarkdownContentView(
            messageID: messageID,
            source: streamingText.text,
            updateID: streamingText.revision,
            sourceIsAppendOnly: true,
            presentation: presentation,
            textLayoutStore: textLayoutStore
        )
        .id(messageID)
    }
}

private struct ChatStreamingMarkdownContentView: View {
    let messageID: String
    let source: String
    let updateID: Int
    let sourceIsAppendOnly: Bool
    let presentation: ChatMarkdownPresentation
    let textLayoutStore: ChatTextLayoutStore

    @State private var worker = ChatStreamingMarkdownRenderWorker()
    @State private var snapshot = ChatStreamingMarkdownSnapshot(
        plan: ChatMarkdownRenderPlan(blocks: []),
        appliedRepairKinds: [],
        stableBlockCount: 0
    )

    var body: some View {
        ChatMarkdownRichContentView(
            layoutIDPrefix: messageID,
            plan: snapshot.plan,
            streamingStableBlockCount: snapshot.stableBlockCount,
            textLayoutStore: textLayoutStore
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ChatMarkdownContentStyle())
        .task(id: updateID) {
            guard let newSnapshot = await worker.render(
                source: source,
                sourceIsAppendOnly: sourceIsAppendOnly
            ),
                !Task.isCancelled
            else { return }

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                snapshot = newSnapshot
            }
        }
        #if DEBUG
            .overlay(alignment: .topTrailing) {
                if presentation.showsDiagnostics {
                    let repairSummary = ChatStreamingMarkdownRepair
                        .diagnosticSummary(for: snapshot.appliedRepairKinds)
                    Text(
                        repairSummary.isEmpty
                            ? "stream rich · \(snapshot.stableBlockCount) stable · \(source.utf8.count.formatted()) bytes"
                            : "stream rich · repair \(repairSummary)"
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

/// Keeps stable timeline updates at a cheap equality check. Settled plans are
/// process-cached so List remounts don't parse unchanged Markdown again.
private struct ChatMarkdownMessageLifetimeView: Equatable, View {
    let messageID: String
    let source: String
    let presentation: ChatMarkdownPresentation
    let textLayoutStore: ChatTextLayoutStore

    nonisolated static func == (
        lhs: ChatMarkdownMessageLifetimeView,
        rhs: ChatMarkdownMessageLifetimeView
    ) -> Bool {
        lhs.messageID == rhs.messageID
            && lhs.source == rhs.source
            && lhs.presentation == rhs.presentation
            && lhs.textLayoutStore === rhs.textLayoutStore
    }

    var body: some View {
        ChatMarkdownRichContentView(
            layoutIDPrefix: messageID,
            plan: ChatMarkdownRenderCache.shared.plan(
                messageID: messageID,
                source: source
            ),
            streamingStableBlockCount: nil,
            textLayoutStore: textLayoutStore
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ChatMarkdownContentStyle())
        #if DEBUG
            .overlay(alignment: .topTrailing) {
                if presentation.showsDiagnostics {
                    Text(
                        "native rich · \(source.count.formatted()) chars"
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
