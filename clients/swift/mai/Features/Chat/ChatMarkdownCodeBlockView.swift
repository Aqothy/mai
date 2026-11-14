import SwiftUI

struct ChatMarkdownCodeBlockView: View {
    let block: ChatMarkdownCodeBlock
    let isStreaming: Bool
    /// Identifies the block's prepared native layout.
    let layoutID: String
    let textLayoutStore: ChatTextLayoutStore

    // Explicit because the private state below would make the memberwise init private.
    init(block: ChatMarkdownCodeBlock, isStreaming: Bool, layoutID: String, textLayoutStore: ChatTextLayoutStore) {
        self.block = block
        self.isStreaming = isStreaming
        self.layoutID = layoutID
        self.textLayoutStore = textLayoutStore
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(block.displayLanguage)
                    .font(.callout)
                    .lineLimit(1)

                Spacer(minLength: 12)

                ChatCopyButton(
                    title: "Copy code",
                    accessibilityHint: "Copies this code block to the Clipboard",
                    text: block.code
                )
            }
            // A fixed line: the native row computes the block's height
            // from the same metric instead of measuring this header.
            .frame(height: ChatRichBlockStyle.codeHeaderContentHeight)
            .padding(.horizontal, ChatRichBlockStyle.codeHeaderHorizontalInset)
            .padding(.top, ChatRichBlockStyle.codeHeaderTopInset)
            .padding(.bottom, ChatRichBlockStyle.codeHeaderBottomInset)

            if isStreaming {
                ScrollView(.horizontal) {
                    Text(block.code)
                        .font(.callout.monospaced())
                        .lineSpacing(ChatCodeBlockStyle.lineSpacing)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, ChatCodeBlockStyle.horizontalInset)
                        .padding(.bottom, ChatCodeBlockStyle.bottomInset)
                }
                .scrollIndicators(.visible, axes: .horizontal)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            } else {
                // A native, prepared text view: the row's height is known
                // before the row exists, and a vertical scroll over the code
                // moves the transcript.
                ChatCodeBlockText(
                    layoutID: layoutID,
                    block: block,
                    theme: colorScheme == .dark ? .dark : .light,
                    layoutStore: textLayoutStore
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(
                ChatRichBlockStyle.codeBackgroundOpacity(isDark: colorScheme == .dark)),
            in: .rect(cornerRadius: ChatRichBlockStyle.codeCornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ChatRichBlockStyle.codeCornerRadius)
                .strokeBorder(Color.primary.opacity(ChatRichBlockStyle.codeBorderOpacity))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(block.displayLanguage) code block")
    }
}
