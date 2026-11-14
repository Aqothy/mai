import SwiftUI

enum ChatTimelineRenderRow: Identifiable {
    case standard(ChatTimelineRowModel)
    case richMarkdown(ChatMessageSegmentRowModel)
    case prose(ChatMessageSegmentRowModel)
    case resolvedMarkdown(ChatResolvedMarkdownBlockRowModel)

    func annotationContext(model: ChatAnnotationModel) -> ChatAnnotationContext? {
        switch self {
        case .prose(let segment), .richMarkdown(let segment):
            ChatAnnotationContext(messageID: segment.messageID, role: segment.role, model: model)
        case .resolvedMarkdown(let block):
            ChatAnnotationContext(messageID: block.messageID, role: ChatRole.assistant.rawValue, model: model)
        case .standard:
            nil
        }
    }

    /// Vertical spacing around one piece of a split message. Native rows
    /// reproduce it exactly, so both hosts share this definition.
    var verticalInsets: (top: CGFloat, bottom: CGFloat) {
        switch self {
        case .standard:
            (0, 0)
        case .prose(let segment), .richMarkdown(let segment):
            (
                segment.isFirst ? ChatTimelineMetrics.rowVerticalInset : 0,
                segment.isLast
                    ? ChatTimelineMetrics.rowVerticalInset : ChatTimelineMetrics.interSegmentSpacing
            )
        case .resolvedMarkdown(let block):
            (
                block.isFirst
                    ? ChatTimelineMetrics.rowVerticalInset : ChatMarkdownProseStyle.blockSpacing,
                block.isLast ? ChatTimelineMetrics.rowVerticalInset : 0
            )
        }
    }

    var id: String {
        switch self {
        case .standard(let row): row.id
        case .richMarkdown(let segment): "\(segment.rowID)-rich"
        case .prose(let segment): "\(segment.rowID)-prose"
        case .resolvedMarkdown(let block): block.rowID
        }
    }
}

/// One stable shape lets the transcript obtain identities without evaluating expensive
/// row bodies for the entire transcript.
struct ChatTimelineRenderRowView: View {
    let row: ChatTimelineRenderRow
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
            case .standard(let model):
                ChatTimelineRow(
                    row: model,
                    streamingTurnID: streamingTurnID,
                    threadID: threadID,
                    store: store,
                    foldModel: foldModel,
                    scrollState: scrollState,
                    annotationModel: annotationModel,
                    textLayoutStore: textLayoutStore
                )

            case .richMarkdown(let segment):
                ChatMessageRow(
                    messageID: segment.rowID,
                    text: segment.source,
                    role: segment.role,
                    annotations: segment.annotations,
                    attachments: segment.attachments,
                    streamingText: nil,
                    presentation: ChatMarkdownPresentation(isStreaming: false),
                    textLayoutStore: textLayoutStore
                )

            case .prose(let segment):
                ChatMessageBubble(
                    role: segment.role,
                    annotations: segment.annotations,
                    attachments: segment.attachments
                ) {
                    ChatSelectableText(
                        layoutID: segment.rowID,
                        content: .source(segment.source),
                        layoutStore: textLayoutStore
                    )
                }

            case .resolvedMarkdown(let block):
                ChatResolvedMarkdownBlockRow(
                    model: block,
                    textLayoutStore: textLayoutStore
                )
            }
        }
        .environment(\.chatAnnotationContext, row.annotationContext(model: annotationModel))
        .padding(.top, row.verticalInsets.top)
        .padding(.bottom, row.verticalInsets.bottom)
        .frame(
            maxWidth: ChatContentMetrics.maximumWidth,
            alignment: .leading
        )
        .frame(maxWidth: .infinity)
    }
}
