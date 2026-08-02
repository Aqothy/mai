import MarkdownView
import SwiftUI

/// Centralized, theme-aware styling for chat Markdown.
///
/// MarkdownView 3 keeps inline code in the surrounding attributed-text flow
/// and distinguishes it with tint/background, but exposes no inline-code font
/// hook. Fenced code uses a small local style because the package's built-in
/// highlighter waits for streaming updates to pause. Math continues to use
/// MarkdownView's built-in renderer. Tables retain one small local style
/// because MarkdownView's built-in table styles do not scroll horizontally at
/// narrow chat widths.
///
/// Links keep MarkdownView's rendering but discard every open request, making
/// assistant-provided destinations display-only in both the mock and final
/// chat views.
struct ChatMarkdownContentStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .markdownMathRenderingEnabled()
            .markdownCodeBlockStyle(ChatMarkdownCodeBlockStyle())
            .markdownTableStyle(ChatMarkdownTableStyle())
            .tint(.primary, for: .link)
            .environment(\.openURL, OpenURLAction { _ in .discarded })
            .lineSpacing(2)
            .task {
                await ChatCodeHighlighter.shared.prepare()
            }
            #if os(iOS) || os(macOS)
                .textSelection(.enabled)
            #endif
    }
}
