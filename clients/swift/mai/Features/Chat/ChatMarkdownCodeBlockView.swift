import SwiftUI

struct ChatMarkdownCodeBlockView: View {
    let block: ChatMarkdownCodeBlock
    let isStreaming: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var highlightedCode: HighlightedCode?

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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(block.displayLanguage) code block")
    }

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
}

private struct HighlightingRequest: Hashable {
    let code: String
    let language: String?
    let theme: ChatCodeHighlightTheme
}

private struct HighlightedCode {
    let request: HighlightingRequest
    let attributed: AttributedString
}
