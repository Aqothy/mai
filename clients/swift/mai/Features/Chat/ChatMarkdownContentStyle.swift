import MarkdownView
import RichText
import SwiftUI

/// Shared Markdown styling that keeps rendered links display-only.
struct ChatMarkdownContentStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textLayoutEngine(.textKit2)
            .markdownMathRenderingEnabled()
            .markdownCodeBlockStyle(
                .default(
                    lightTheme: "atom-one-light",
                    darkTheme: "atom-one-dark"
                )
            )
            .markdownTableStyle(ChatMarkdownTableStyle())
            .tint(.primary, for: .link)
            .environment(\.openURL, OpenURLAction { _ in .discarded })
            .lineSpacing(2)
            #if os(iOS) || os(macOS)
                .textSelection(.enabled)
            #endif
    }
}
