import SwiftUI

struct ChatMarkdownCodeBlockView: View {
    let block: ChatMarkdownCodeBlock
    let isStreaming: Bool
    /// Identifies the block's prepared native layout on macOS.
    let layoutID: String
    let textLayoutStore: ChatTextLayoutStore

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
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            #if os(macOS)
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
            #else
                ScrollView(.horizontal) {
                    Text(displayedCode)
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
            Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.055),
            in: .rect(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.primary.opacity(0.08))
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
