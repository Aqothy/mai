import SwiftUI

/// Renders an immutable Markdown plan. Each block is equatable so an appended
/// streaming tail doesn't rebuild stable code, table, or prose views.
struct ChatMarkdownRichContentView: View {
    let plan: ChatMarkdownRenderPlan
    let streamingStableBlockCount: Int?
    let hasOpenCodeFence: Bool

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 0
        ) {
            ForEach(plan.blocks.indices, id: \.self) { index in
                let block = plan.blocks[index]
                ChatMarkdownRenderBlockView(
                    block: block,
                    isStreamingCode: isStreamingCode(
                        block,
                        at: index
                    ),
                    usesSelectableProse: streamingStableBlockCount.map {
                        index < $0
                    } ?? true,
                    proseLayoutID: "markdown-prose-\(index)"
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

    private func isStreamingCode(
        _ block: ChatMarkdownRenderPlan.Block,
        at index: Int
    ) -> Bool {
        guard let stableBlockCount = streamingStableBlockCount,
            index >= stableBlockCount,
            case .code(let code) = block
        else { return false }

        return switch code.kind {
        case .fenced:
            hasOpenCodeFence && index == plan.blocks.indices.last
        case .html:
            true
        }
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
            presentation: ChatMarkdownPresentation(isStreaming: false)
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

private struct ChatMarkdownRenderBlockView: Equatable, View {
    let block: ChatMarkdownRenderPlan.Block
    let isStreamingCode: Bool
    let usesSelectableProse: Bool
    let proseLayoutID: String

    var body: some View {
        switch block {
        case .prose(let prose):
            if usesSelectableProse {
                ChatSelectableMarkdownProseRun(
                    layoutID: proseLayoutID,
                    prose: prose
                )
                .equatable()
            } else {
                ChatStreamingMarkdownProseView(prose: prose)
            }

        case .code(let codeBlock):
            ChatMarkdownCodeBlockView(
                block: codeBlock,
                isStreaming: isStreamingCode
            )

        case .table(let table):
            ChatMarkdownTableView(table: table)
        }
    }
}

/// Gives each completed prose run the existing selectable renderer and a
/// small local cache. The actively changing tail never enters this view.
private struct ChatSelectableMarkdownProseRun: Equatable, View {
    let layoutID: String
    let prose: ChatMarkdownProseRun

    @State private var layoutStore = ChatTextLayoutStore()

    nonisolated static func == (
        lhs: ChatSelectableMarkdownProseRun,
        rhs: ChatSelectableMarkdownProseRun
    ) -> Bool {
        lhs.layoutID == rhs.layoutID && lhs.prose == rhs.prose
    }

    var body: some View {
        ChatSelectableText(
            layoutID: layoutID,
            source: prose.source,
            style: .markdownProse,
            layoutStore: layoutStore
        )
    }
}

private struct ChatStreamingMarkdownProseView: Equatable, View {
    let prose: ChatMarkdownProseRun

    var body: some View {
        VStack(alignment: .leading, spacing: ChatMarkdownProseStyle.blockSpacing) {
            ForEach(prose.pieces.indices, id: \.self) { index in
                ChatStreamingMarkdownProsePieceView(
                    piece: prose.pieces[index]
                )
                .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatStreamingMarkdownProsePieceView: Equatable, View {
    let piece: ChatMarkdownProseRun.Piece

    var body: some View {
        switch piece {
        case .text(let text):
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .quote(let quote):
            Text(quote)
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

        case .thematicBreak:
            Divider()
                .frame(maxWidth: .infinity)
        }
    }
}
