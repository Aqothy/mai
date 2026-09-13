import SwiftUI

struct ChatMarkdownCodeBlockView: View {
    let block: ChatMarkdownCodeBlock
    let isStreaming: Bool
    /// Identifies the block's prepared native layout on macOS.
    let layoutID: String
    let textLayoutStore: ChatTextLayoutStore
    let revealBatches: [ChatStreamingTextRevealBatch]

    init(block: ChatMarkdownCodeBlock, isStreaming: Bool, layoutID: String, textLayoutStore: ChatTextLayoutStore, revealBatches: [ChatStreamingTextRevealBatch] = []) {
        self.block = block
        self.isStreaming = isStreaming
        self.layoutID = layoutID
        self.textLayoutStore = textLayoutStore
        self.revealBatches = revealBatches
    }

    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
        @State private var highlightedCode: HighlightedCode?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(block.displayLanguage)
                    .font(.callout)

                Spacer(minLength: 12)

                ChatCopyButton(
                    title: "Copy code",
                    accessibilityHint: "Copies this code block to the Clipboard",
                    text: block.code
                )
            }
            .padding(.horizontal, ChatRichBlockStyle.codeHeaderHorizontalInset)
            .padding(.top, ChatRichBlockStyle.codeHeaderTopInset)
            .padding(.bottom, ChatRichBlockStyle.codeHeaderBottomInset)

            #if os(macOS)
                if isStreaming {
                    ScrollView(.horizontal) {
                        ChatStreamingTextRevealView(
                            text: AttributedString(block.code), batches: revealBatches
                        )
                        .font(.callout.monospaced())
                        .lineSpacing(ChatMacCodeStyle.lineSpacing)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, ChatMacCodeStyle.horizontalInset)
                        .padding(.bottom, ChatMacCodeStyle.bottomInset)
                    }
                    .scrollIndicators(.visible, axes: .horizontal)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                } else {
                    // A native, prepared text view: the row's height is known
                    // before the row exists and vertical wheel gestures pass
                    // through to the transcript.
                    ChatMacCodeBlockText(
                        layoutID: layoutID,
                        block: block,
                        theme: colorScheme == .dark ? .dark : .light,
                        isStreaming: isStreaming,
                        layoutStore: textLayoutStore
                    )
                }
            #else
                ScrollView(.horizontal) {
                    ChatStreamingTextRevealView(text: displayedCode, batches: revealBatches)
                        .font(.callout.monospaced())
                        .lineSpacing(4)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                .scrollIndicators(.visible, axes: .horizontal)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
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
        #if os(iOS)
            .task(id: highlightingRequest) {
                guard let request = highlightingRequest else {
                    highlightedCode = nil
                    return
                }
                let result = await ChatCodeHighlighter.shared.highlight(
                    code: request.code,
                    language: request.language,
                    theme: request.theme
                )
                guard !Task.isCancelled else { return }
                highlightedCode = result.map {
                    HighlightedCode(request: request, attributed: $0)
                }
            }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(block.displayLanguage) code block")
    }

    #if os(iOS)
        private var highlightingRequest: HighlightingRequest? {
            guard !isStreaming, !block.code.isEmpty else { return nil }
            return HighlightingRequest(
                code: block.code,
                language: block.language,
                theme: colorScheme == .dark ? .dark : .light
            )
        }

        private var displayedCode: AttributedString {
            guard let highlightedCode,
                highlightedCode.request == highlightingRequest
            else { return AttributedString(block.code) }
            return highlightedCode.attributed
        }
    #endif
}

#if os(iOS)
    private struct HighlightingRequest: Hashable {
        let code: String
        let language: String?
        let theme: ChatCodeHighlightTheme
    }

    private struct HighlightedCode {
        let request: HighlightingRequest
        let attributed: AttributedString
    }
#endif
