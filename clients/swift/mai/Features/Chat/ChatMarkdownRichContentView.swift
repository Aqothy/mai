import SwiftUI

/// Renders an immutable Markdown plan. Each block is equatable so an appended
/// streaming tail doesn't rebuild stable code, table, or prose views.
struct ChatMarkdownRichContentView: View {
    let plan: ChatMarkdownRenderPlan
    let allowsHighlighting: Bool

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: ChatMarkdownProseStyle.blockSpacing
        ) {
            ForEach(plan.blocks.indices, id: \.self) { index in
                ChatMarkdownRenderBlockView(
                    block: plan.blocks[index],
                    allowsHighlighting: allowsHighlighting
                )
                .equatable()
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
    let allowsHighlighting: Bool

    var body: some View {
        switch block {
        case .prose(let attributedString):
            Text(attributedString)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .code(let codeBlock):
            ChatMarkdownCodeBlockView(
                block: codeBlock,
                allowsHighlighting: allowsHighlighting
            )

        case .table(let table):
            ChatMarkdownTableView(table: table)
        }
    }
}
