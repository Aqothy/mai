import SwiftUI

struct ChatMarkdownMessageView: View {
    let messageID: String
    let source: String
    let presentation: ChatMarkdownPresentation

    var body: some View {
        Group {
            if presentation.isStreaming {
                ChatStreamingMarkdownContentView(
                    source: source,
                    // Production supplies a monotonic revision below. This
                    // value path exists for previews and deterministic labs,
                    // whose streams are append-only between replacements.
                    updateID: source.utf8.count,
                    sourceIsAppendOnly: false,
                    presentation: presentation
                )
            } else {
                ChatMarkdownMessageLifetimeView(
                    messageID: messageID,
                    source: source,
                    presentation: presentation
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

    var body: some View {
        ChatStreamingMarkdownContentView(
            source: streamingText.text,
            updateID: streamingText.revision,
            sourceIsAppendOnly: true,
            presentation: presentation
        )
        .id(messageID)
    }
}

private struct ChatStreamingMarkdownContentView: View {
    let source: String
    let updateID: Int
    let sourceIsAppendOnly: Bool
    let presentation: ChatMarkdownPresentation

    @State private var worker = ChatStreamingMarkdownRenderWorker()
    @State private var plan = ChatMarkdownRenderPlan(blocks: [])
    @State private var appliedRepairKinds: Set<
        ChatStreamingMarkdownRepair.Kind
    > = []
    @State private var stableBlockCount = 0

    var body: some View {
        ChatMarkdownRichContentView(
            plan: plan,
            streamingStableBlockCount: stableBlockCount,
            hasOpenCodeFence: appliedRepairKinds.contains(.codeFence)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ChatMarkdownContentStyle())
        .task(id: updateID) {
            guard let snapshot = await worker.render(
                source: source,
                sourceIsAppendOnly: sourceIsAppendOnly
            ),
                !Task.isCancelled
            else { return }

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                plan = snapshot.plan
                appliedRepairKinds = snapshot.appliedRepairKinds
                stableBlockCount = snapshot.stableBlockCount
            }
        }
        #if DEBUG
            .overlay(alignment: .topTrailing) {
                if presentation.showsDiagnostics {
                    let repairSummary = ChatStreamingMarkdownRepair
                        .diagnosticSummary(for: appliedRepairKinds)
                    Text(
                        repairSummary.isEmpty
                            ? "stream rich · \(stableBlockCount) stable · \(source.utf8.count.formatted()) bytes"
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

    nonisolated static func == (
        lhs: ChatMarkdownMessageLifetimeView,
        rhs: ChatMarkdownMessageLifetimeView
    ) -> Bool {
        lhs.messageID == rhs.messageID
            && lhs.source == rhs.source
            && lhs.presentation == rhs.presentation
    }

    var body: some View {
        ChatMarkdownRichContentView(
            plan: ChatMarkdownRenderCache.shared.plan(
                messageID: messageID,
                source: source
            ),
            streamingStableBlockCount: nil,
            hasOpenCodeFence: false
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
