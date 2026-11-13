import SwiftUI

struct ChatTimelineRow: View {
    let row: ChatTimelineRowModel
    let streamingTurnID: String?
    let threadID: String
    let store: ThreadStore
    let foldModel: ChatTimelineFoldModel
    let scrollState: ChatScrollState
    let annotationModel: ChatAnnotationModel
    let textLayoutStore: ChatTextLayoutStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch row {
            case .message(let message):
                ChatMessageRow(
                    messageID: message.id,
                    text: message.text,
                    role: message.role,
                    annotations: message.annotations,
                    attachments: message.attachments,
                    streamingText: store.streamingText(threadID: threadID, rowID: message.id),
                    presentation: ChatMarkdownPresentation.timelineMessage(
                        role: message.role,
                        turnID: message.turnID,
                        streamingTurnID: streamingTurnID
                    ),
                    textLayoutStore: textLayoutStore
                )
                .environment(
                    \.chatAnnotationContext,
                    ChatAnnotationContext(
                        messageID: message.id,
                        role: message.role,
                        model: annotationModel
                    )
                )
                .padding(.vertical, 10)
            case .thought(let item):
                ChatThoughtRow(
                    item: item,
                    streamingText: store.streamingText(threadID: threadID, rowID: item.id),
                    foldModel: foldModel,
                    scrollState: scrollState
                )
            case .turnActivity(let activity):
                ChatTurnActivityRow(
                    activity: activity,
                    foldModel: foldModel,
                    scrollState: scrollState
                )
            case .activityGroup(let group):
                // A lone step needs no group wrapper: one tap reaches it.
                if group.items.count == 1, let item = group.items.first {
                    ChatActivityItemRow(
                        item: item,
                        threadID: threadID,
                        store: store,
                        foldModel: foldModel,
                        scrollState: scrollState
                    )
                    .padding(.vertical, 4)
                } else {
                    ChatActivityGroupRow(
                        group: group,
                        threadID: threadID,
                        store: store,
                        foldModel: foldModel,
                        scrollState: scrollState
                    )
                }
            case .notice(let item):
                ChatNoticeRow(item: item)
            case .handoff(let item):
                ChatHandoffRow(item: item, threadID: threadID, store: store)
            case .envelope(let item):
                ChatEnvelopeRow(item: item)
            case .stopNote(let note):
                Label(note.text, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            case .turnFork(let fork):
                ChatTurnForkRow(fork: fork)
            case .request(let request):
                ChatRequestRow(request: request, threadID: threadID, store: store)
                    // An answered request shows its record: fresh state.
                    .id(request.isOpen)
                    .padding(.vertical, 10)
            }
        }
    }
}

struct ChatMessageRow: View {
    let messageID: String
    let text: String
    let role: String
    let annotations: [PromptAnnotation]?
    let attachments: [Attachment]?
    let streamingText: ThreadStreamingText?
    let presentation: ChatMarkdownPresentation
    let textLayoutStore: ChatTextLayoutStore

    var body: some View {
        ChatMessageBubble(role: role, annotations: annotations, attachments: attachments) {
            if !text.isEmpty {
                // A restored thread can retain a replayed streaming buffer
                // for its final messages. Once the message presents as
                // settled, the settled renderer must win: its layouts are the
                // ones preparation primes, and the buffer may lag the
                // reduced timeline text.
                if let streamingText, presentation.isStreaming {
                    ChatStreamingMarkdownMessageView(
                        messageID: messageID,
                        streamingText: streamingText,
                        presentation: presentation,
                        textLayoutStore: textLayoutStore
                    )
                } else {
                    ChatMarkdownMessageView(
                        messageID: messageID,
                        source: text,
                        presentation: presentation,
                        textLayoutStore: textLayoutStore
                    )
                }
            }
        }
    }
}

/// Warnings and errors stay visible outside the fold.
private struct ChatNoticeRow: View {
    let item: ChatItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                item.title ?? ChatTimelineText.humanized(item.kind),
                systemImage: item.itemKind == .error
                    ? "xmark.octagon" : "exclamationmark.triangle"
            )
            .font(.callout.weight(.semibold))

            if let text = ChatTimelineLayout.reasoningText(item) {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(
            item.itemKind == .error ? .red.opacity(0.12) : .orange.opacity(0.12),
            in: .rect(cornerRadius: 12)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}
