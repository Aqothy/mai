import SwiftUI

/// The model's reasoning behind a "Thought" disclosure — open while the
/// thought streams, folding on its own once the item settles.
/// Reasoning uses Foundation's inline Markdown parser because it has its own
/// compact font and secondary color rather than the document-level styling of
/// assistant messages.
struct ChatThoughtRow: View {
    let item: ChatItem
    let streamingText: ThreadStreamingText?
    let foldModel: ChatTimelineFoldModel
    let scrollState: ChatScrollState

    var body: some View {
        if let text = ChatTimelineLayout.reasoningText(item) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    scrollState.noteContentExpansion()
                    foldModel.setExpanded(.thought(itemID: item.id), !isExpanded)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "brain")
                            .font(.caption)
                            .frame(width: 16)

                        ChatActivityGroupRow.itemLineText(item)

                        Image(
                            systemName: isExpanded
                                ? "chevron.down" : "chevron.right"
                        )
                        .font(.caption2.weight(.semibold))
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isExpanded ? "Hide thought" : "Show thought"
                )

                if isExpanded {
                    ChatThoughtText(
                        fallbackText: text,
                        streamingText: streamingText
                    )
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Untouched thoughts are open only while streaming; an explicit choice
    /// survives completion and offscreen reuse.
    private var isExpanded: Bool {
        foldModel.isExpanded(
            .thought(itemID: item.id),
            default: item.itemStatus == .inProgress
        )
    }
}

/// Owns the only observation read for a live thought. The disclosure row and
/// surrounding transcript retain stable inputs while this leaf updates.
private struct ChatThoughtText: View {
    let fallbackText: String
    let streamingText: ThreadStreamingText?

    var body: some View {
        Group {
            if let streamingText {
                ChatLiveThoughtText(
                    streamingText: streamingText,
                    seedText: fallbackText
                )
            } else {
                Text(Self.attributed(fallbackText))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    nonisolated static func attributed(_ text: String) -> AttributedString {
        guard
            let parsed = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        else {
            return AttributedString(text)
        }
        return parsed
    }
}

/// Displays one live reasoning buffer, mirroring how the assistant message
/// text streams: this leaf is the only view observing the buffer, and each
/// flushed update parses off the main actor.
///
/// The daemon coalesces reasoning chunks on a 50 ms ticker, so the leaf
/// re-evaluates at most 20 times per second; the body itself only swaps in a
/// finished attributed string. A newer revision cancels an in-flight parse,
/// so superseded text is never rendered. The initial display seeds from
/// `seedText`, the settled-payload snapshot the parent already carries, so
/// the row shows text on its first frame. When the item settles the store
/// clears the buffer and the parent swaps to the settled payload text.
private struct ChatLiveThoughtText: View {
    let streamingText: ThreadStreamingText

    @State private var rendered: AttributedString

    init(streamingText: ThreadStreamingText, seedText: String) {
        self.streamingText = streamingText
        _rendered = State(initialValue: ChatThoughtText.attributed(seedText))
    }

    var body: some View {
        Text(rendered)
            .task(id: streamingText.revision) {
                let parsed = await Self.parse(streamingText.text)
                guard !Task.isCancelled else { return }
                rendered = parsed
            }
    }

    /// Streamed reasoning carries leading/trailing newlines that the settled
    /// row trims; trim the live text the same way before parsing.
    @concurrent
    private static func parse(_ text: String) async -> AttributedString {
        ChatThoughtText.attributed(
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
