import SwiftUI

/// Renders an immutable Markdown plan. Each block is equatable so an appended
/// streaming tail doesn't rebuild stable code, table, or prose views.
struct ChatMarkdownRichContentView: View {
    let layoutIDPrefix: String
    let plan: ChatMarkdownRenderPlan
    let streamingStableBlockCount: Int?
    let streamingRevealBatches: [ChatStreamingTextRevealBatch]
    let textLayoutStore: ChatTextLayoutStore

    init(
        layoutIDPrefix: String,
        plan: ChatMarkdownRenderPlan,
        streamingStableBlockCount: Int?,
        streamingRevealBatches: [ChatStreamingTextRevealBatch] = [],
        textLayoutStore: ChatTextLayoutStore
    ) {
        self.layoutIDPrefix = layoutIDPrefix
        self.plan = plan
        self.streamingStableBlockCount = streamingStableBlockCount
        self.streamingRevealBatches = streamingRevealBatches
        self.textLayoutStore = textLayoutStore
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 0
        ) {
            ForEach(plan.blocks.indices, id: \.self) { index in
                let block = plan.blocks[index]
                let isStreamingBlock =
                    streamingStableBlockCount.map {
                        index >= $0
                    } ?? false
                let revealBatches =
                    isStreamingBlock
                        && index == plan.blocks.indices.last
                    ? streamingRevealBatches : []
                ChatMarkdownRenderBlockView(
                    block: block,
                    isStreaming: isStreamingBlock,
                    revealBatches: revealBatches,
                    layoutID: "\(layoutIDPrefix)-block-\(index)",
                    textLayoutStore: textLayoutStore
                )
                .equatable()
                .padding(
                    .top,
                    index == 0 ? 0 : ChatMarkdownProseStyle.blockSpacing
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Rich Markdown – Dark") {
    ScrollView {
        ChatMarkdownMessageView(
            messageID: "rich-markdown-preview",
            source: #"""
                ## Code block

                ```python
                def greet(name):
                    return f"Hello, {name}!"

                print(greet("World"))
                ```

                ## Table

                | Item | Type | Example |
                | --- | --- | --- |
                | Code | Python | `print("Hello")` |
                | HTML | Element | `<div>` |
                | Image | Markdown | `![Alt text](image.png)` |

                ## Horizontal rule

                Content before the rule.

                ---

                Content after the rule.

                ## HTML block

                <div>HTML remains inert.</div>
                """#,
            presentation: ChatMarkdownPresentation(isStreaming: false),
            textLayoutStore: ChatTextLayoutStore()
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

private struct ChatMarkdownRenderBlockView: Equatable, View {
    let block: ChatMarkdownRenderPlan.Block
    let isStreaming: Bool
    let revealBatches: [ChatStreamingTextRevealBatch]
    let layoutID: String
    let textLayoutStore: ChatTextLayoutStore

    nonisolated static func == (
        lhs: ChatMarkdownRenderBlockView,
        rhs: ChatMarkdownRenderBlockView
    ) -> Bool {
        lhs.block == rhs.block
            && lhs.isStreaming == rhs.isStreaming
            && lhs.revealBatches == rhs.revealBatches
            && lhs.layoutID == rhs.layoutID
            && lhs.textLayoutStore === rhs.textLayoutStore
    }

    var body: some View {
        switch block {
        case .prose(let prose):
            if !isStreaming {
                ChatSelectableMarkdownProseRun(
                    layoutID: layoutID,
                    prose: prose,
                    textLayoutStore: textLayoutStore
                )
                .equatable()
            } else {
                ChatMarkdownResolvedProseView(
                    prose: prose,
                    revealBatches: revealBatches
                )
            }

        case .code(let codeBlock):
            ChatMarkdownCodeBlockView(
                block: codeBlock,
                isStreaming: isStreaming,
                layoutID: layoutID,
                textLayoutStore: textLayoutStore,
                revealBatches: revealBatches
            )

        case .table(let table):
            ChatMarkdownTableView(
                table: table,
                layoutID: layoutID,
                textLayoutStore: textLayoutStore
            )
        }
    }
}

/// Completed prose uses the thread-owned layout and native-view cache. The
/// actively changing tail never enters this view.
private struct ChatSelectableMarkdownProseRun: Equatable, View {
    let layoutID: String
    let prose: ChatMarkdownProseRun
    let textLayoutStore: ChatTextLayoutStore

    nonisolated static func == (
        lhs: ChatSelectableMarkdownProseRun,
        rhs: ChatSelectableMarkdownProseRun
    ) -> Bool {
        lhs.layoutID == rhs.layoutID
            && lhs.prose == rhs.prose
            && lhs.textLayoutStore === rhs.textLayoutStore
    }

    var body: some View {
        ChatSelectableText(
            layoutID: layoutID,
            source: prose.source,
            style: .markdownProse,
            layoutStore: textLayoutStore
        )
    }
}

private struct ChatMarkdownResolvedProseView: Equatable, View {
    let prose: ChatMarkdownProseRun
    var revealBatches: [ChatStreamingTextRevealBatch] = []

    var body: some View {
        VStack(alignment: .leading, spacing: ChatMarkdownProseStyle.blockSpacing) {
            ForEach(prose.pieces.indices, id: \.self) { index in
                ChatMarkdownResolvedProsePieceView(
                    piece: prose.pieces[index],
                    revealBatches: index == prose.pieces.indices.last
                        ? revealBatches : []
                )
                .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

enum ChatResolvedMarkdownRowContent: Equatable {
    case prose(ChatMarkdownProseRun.Piece)
    case proseRun(ChatMarkdownProseRun)
    case code(ChatMarkdownCodeBlock)
    case table(ChatMarkdownTable)
}

nonisolated enum ChatResolvedMarkdownRowPlanner {
    static func contents(
        in plan: ChatMarkdownRenderPlan
    ) -> [ChatResolvedMarkdownRowContent] {
        plan.blocks.flatMap { block in
            switch block {
            case .prose(let prose):
                #if os(macOS)
                    [ChatResolvedMarkdownRowContent.proseRun(prose)]
                #else
                    prose.pieces.map(ChatResolvedMarkdownRowContent.prose)
                #endif
            case .code(let code):
                [ChatResolvedMarkdownRowContent.code(code)]
            case .table(let table):
                [ChatResolvedMarkdownRowContent.table(table)]
            }
        }
    }
}

struct ChatResolvedMarkdownBlockRowModel {
    let messageID: String
    let index: Int
    let content: ChatResolvedMarkdownRowContent
    let attachments: [Attachment]?
    let isFirst: Bool
    let isLast: Bool

    var rowID: String { "\(messageID)#resolved-block-\(index)" }
}

/// One parser-resolved block promoted to a lazy timeline row when source-level
/// segmentation would change document-wide Markdown semantics.
struct ChatResolvedMarkdownBlockRow: View {
    let model: ChatResolvedMarkdownBlockRowModel
    let textLayoutStore: ChatTextLayoutStore

    var body: some View {
        VStack(alignment: .leading) {
            switch model.content {
            case .prose(let piece):
                ChatMarkdownResolvedProsePieceView(piece: piece)
                    .equatable()
                    .textSelection(.enabled)
            case .proseRun(let prose):
                #if os(macOS)
                    ChatSelectableResolvedProse(
                        layoutID: model.rowID,
                        prose: prose,
                        layoutStore: textLayoutStore
                    )
                #else
                    ChatMarkdownResolvedProseView(prose: prose)
                #endif
            case .code(let code):
                ChatMarkdownCodeBlockView(
                    block: code,
                    isStreaming: false,
                    layoutID: model.rowID,
                    textLayoutStore: textLayoutStore
                )
            case .table(let table):
                ChatMarkdownTableView(
                    table: table,
                    layoutID: model.rowID,
                    textLayoutStore: textLayoutStore
                )
            }

            if let attachments = model.attachments, !attachments.isEmpty {
                ChatMessageAttachmentsView(attachments: attachments)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ChatMarkdownContentStyle())
    }
}

struct ChatMarkdownResolvedProsePieceView: Equatable, View {
    let piece: ChatMarkdownProseRun.Piece
    let revealBatches: [ChatStreamingTextRevealBatch]

    init(
        piece: ChatMarkdownProseRun.Piece,
        revealBatches: [ChatStreamingTextRevealBatch] = []
    ) {
        self.piece = piece
        self.revealBatches = revealBatches
    }

    var body: some View {
        switch piece {
        case .text(let text):
            ChatStreamingTextRevealView(
                text: text,
                batches: revealBatches
            )
            .frame(maxWidth: .infinity, alignment: .leading)
                .chatTextPointerStyle()

        case .quote(let quote):
            ChatStreamingTextRevealView(
                text: quote,
                batches: revealBatches
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(
                .leading,
                ChatMarkdownProseStyle.quoteBarWidth
                    + ChatMarkdownProseStyle.quoteIndent
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(
                    cornerRadius: ChatMarkdownProseStyle.quoteBarWidth / 2
                )
                .fill(Color.secondary.opacity(0.35))
                .frame(width: ChatMarkdownProseStyle.quoteBarWidth)
                .accessibilityHidden(true)
            }
                .chatTextPointerStyle()

        case .thematicBreak:
            Divider()
                .frame(maxWidth: .infinity)
        }
    }
}
