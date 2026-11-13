import SwiftUI

struct ChatMessageSegmentRowModel {
    let messageID: String
    let index: Int
    let source: String
    let role: String
    let annotations: [PromptAnnotation]?
    let attachments: [Attachment]?
    let isFirst: Bool
    let isLast: Bool

    var rowID: String { "\(messageID)#segment-\(index)" }
}

/// The shared message layout: a trailing user bubble or a full-width
/// assistant column, followed by annotation cards and attachments.
struct ChatMessageBubble<Content: View>: View {
    let role: String
    var annotations: [PromptAnnotation]? = nil
    var attachments: [Attachment]? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        let isUser = role == ChatRole.user.rawValue
        VStack(alignment: .leading) {
            content()

            if let annotations, !annotations.isEmpty {
                ChatMessageAnnotationsView(annotations: annotations)
            }

            if let attachments, !attachments.isEmpty {
                ChatMessageAttachmentsView(attachments: attachments)
            }
        }
        .padding(.horizontal, isUser ? ChatTimelineMetrics.userBubbleHorizontalPadding : 0)
        .padding(.vertical, isUser ? ChatTimelineMetrics.userBubbleVerticalPadding : 0)
        .background(
            isUser ? Color.accentColor.opacity(0.15) : Color.clear,
            in: .rect(cornerRadius: 18)
        )
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}
