import SwiftUI

/// Renders an immutable Markdown plan. Each block is equatable so an appended
/// streaming tail doesn't rebuild stable code, table, or prose views.
struct ChatMarkdownRichContentView: View {
    let layoutIDPrefix: String
    let plan: ChatMarkdownRenderPlan
    let streamingStableBlockCount: Int?
    let textLayoutStore: ChatTextLayoutStore

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
                ChatMarkdownRenderBlockView(
                    block: block,
                    isStreaming: isStreamingBlock,
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

#if DEBUG
    private let chatMarkdownParitySource = #"""
        ## Heading two
        ### Heading three
        Paragraph with *italic*, **bold**, ~~strike~~, `inline code` and a [link](https://example.com).

        - Bullet one
        - Bullet two
          - Nested bullet
            1. Nested ordered

        1. First
        2. Second

        > Quote with **bold** and `code`.
        >
        > > Nested quote

        ---

        | Name | Value |
        | :--- | ---: |
        | **Bold** | `code` |
        | [Link](https://example.com) | ~~old~~ *new* |
        """#

    /// Settled and live presentations of the same plan must look identical.
    #Preview("Markdown parity – settled") {
        ScrollView {
            ChatMarkdownRichContentView(
                layoutIDPrefix: "parity-settled",
                plan: ChatMarkdownRenderPlanner.plan(from: chatMarkdownParitySource),
                streamingStableBlockCount: nil,
                textLayoutStore: ChatTextLayoutStore()
            )
            .padding()
        }
        .frame(width: 420, height: 760)
    }

    #Preview("Markdown parity – streaming") {
        ScrollView {
            ChatMarkdownRichContentView(
                layoutIDPrefix: "parity-streaming",
                plan: ChatMarkdownRenderPlanner.plan(from: chatMarkdownParitySource),
                streamingStableBlockCount: 0,
                textLayoutStore: ChatTextLayoutStore()
            )
            .padding()
        }
        .frame(width: 420, height: 760)
    }
#endif

private struct ChatMarkdownRenderBlockView: Equatable, View {
    let block: ChatMarkdownRenderPlan.Block
    let isStreaming: Bool
    let layoutID: String
    let textLayoutStore: ChatTextLayoutStore

    nonisolated static func == (
        lhs: ChatMarkdownRenderBlockView,
        rhs: ChatMarkdownRenderBlockView
    ) -> Bool {
        lhs.block == rhs.block
            && lhs.isStreaming == rhs.isStreaming
            && lhs.layoutID == rhs.layoutID
            && lhs.textLayoutStore === rhs.textLayoutStore
    }

    var body: some View {
        switch block {
        case .prose(let prose):
            // The live tail renders through the same TextKit path as settled
            // prose, so it stays selectable and never restyles on settle.
            ChatSelectableMarkdownProseRun(
                layoutID: layoutID,
                prose: prose,
                textLayoutStore: textLayoutStore
            )
            .equatable()

        case .code(let codeBlock):
            ChatMarkdownCodeBlockView(
                block: codeBlock,
                isStreaming: isStreaming,
                layoutID: layoutID,
                textLayoutStore: textLayoutStore
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

/// Prose uses the thread-owned layout and native-view cache.
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
            content: .rendered(prose.text),
            layoutStore: textLayoutStore
        )
    }
}

enum ChatResolvedMarkdownRowContent: Equatable {
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
                [ChatResolvedMarkdownRowContent.proseRun(prose)]
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
            case .proseRun(let prose):
                ChatSelectableText(
                    layoutID: model.rowID,
                    content: .rendered(prose.text),
                    layoutStore: textLayoutStore
                )
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
