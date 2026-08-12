import SwiftUI

/// Shared native-prose behavior. Links remain visible but display-only until
/// chat navigation has an explicit policy for external destinations.
struct ChatMarkdownContentStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(.primary)
            .environment(\.openURL, OpenURLAction { _ in .discarded })
            .lineSpacing(2)
            #if os(iOS) || os(macOS)
                .textSelection(.enabled)
            #endif
    }
}
