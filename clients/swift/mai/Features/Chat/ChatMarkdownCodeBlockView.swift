import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

struct ChatMarkdownCodeBlockView: View {
    let block: ChatMarkdownCodeBlock
    let isStreaming: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var highlightedCode: HighlightedCode?
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(block.displayLanguage)
                    .font(.callout)

                Spacer(minLength: 12)

                Button(
                    copied ? "Copied" : "Copy code",
                    systemImage: copied ? "checkmark" : "square.on.square",
                    action: copyCode
                )
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .accessibilityHint("Copies this code block to the Clipboard")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            #if os(macOS)
                ChatMacHorizontalScrollView {
                    ChatMarkdownCodeScrollContent(
                        code: block.code,
                        isStreaming: isStreaming,
                        selectableCode: selectableCode
                    )
                }
            #else
                ScrollView(.horizontal) {
                    #if os(iOS)
                        ChatMarkdownCodeScrollContent(
                            code: block.code,
                            isStreaming: isStreaming,
                            selectableCode: selectableCode
                        )
                    #else
                        ChatMarkdownCodeScrollContent(
                            code: block.code,
                            isStreaming: isStreaming,
                            displayedHighlightedCode: displayedHighlightedCode
                        )
                    #endif
                }
                .scrollIndicators(.visible, axes: .horizontal)
                .scrollIndicatorsFlash(onAppear: true)
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
                HighlightedCode(
                    request: request,
                    attributed: $0
                )
            }
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(block.displayLanguage) code block")
    }

    private var highlightingRequest: HighlightingRequest? {
        guard !isStreaming, !block.code.isEmpty else {
            return nil
        }
        return HighlightingRequest(
            code: block.code,
            language: block.language,
            theme: colorScheme == .dark ? .dark : .light
        )
    }

    private var displayedHighlightedCode: AttributedString? {
        guard highlightedCode?.request == highlightingRequest else {
            return nil
        }
        return highlightedCode?.attributed
    }

    #if os(iOS) || os(macOS)
        private var selectableCode: NSAttributedString {
            let source: NSAttributedString
            if let displayedHighlightedCode {
                source = NSAttributedString(displayedHighlightedCode)
            } else {
                source = NSAttributedString(string: block.code)
            }
            let attributedString = NSMutableAttributedString(
                attributedString: source
            )
            let range = NSRange(
                location: 0,
                length: attributedString.length
            )
            attributedString.addAttributes(
                [
                    .font: codeFont,
                    .paragraphStyle: codeParagraphStyle,
                ],
                range: range
            )
            if displayedHighlightedCode == nil {
                attributedString.addAttribute(
                    .foregroundColor,
                    value: defaultCodeColor,
                    range: range
                )
            }
            return attributedString
        }

        private var codeFont: Any {
            #if os(iOS)
                UIFont.monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .callout)
                        .pointSize,
                    weight: .regular
                )
            #else
                NSFont.monospacedSystemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .callout)
                        .pointSize,
                    weight: .regular
                )
            #endif
        }

        private var defaultCodeColor: Any {
            #if os(iOS)
                UIColor.label
            #else
                NSColor.labelColor
            #endif
        }

        private var codeParagraphStyle: NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            return paragraph
        }
    #endif

    private func copyCode() {
        #if os(iOS)
            UIPasteboard.general.string = block.code
        #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(block.code, forType: .string)
        #endif

        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

private struct ChatMarkdownCodeScrollContent: View {
    let code: String
    let isStreaming: Bool

    #if os(iOS) || os(macOS)
        let selectableCode: NSAttributedString
    #else
        let displayedHighlightedCode: AttributedString?
    #endif

    var body: some View {
        if isStreaming {
            Text(verbatim: code)
                .font(.callout.monospaced())
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        } else {
            #if os(iOS) || os(macOS)
                ChatSelectableRichText(attributedString: selectableCode)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            #else
                Text(displayedHighlightedCode ?? AttributedString(code))
                    .font(.callout.monospaced())
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            #endif
        }
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
