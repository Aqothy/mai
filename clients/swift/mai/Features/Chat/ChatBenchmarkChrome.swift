import SwiftUI

/// Applies a piece of chat chrome (the composer bar) except in a
/// transcript-only benchmark run, which measures the transcript alone.
struct ChatBenchmarkChrome<Chrome: ViewModifier>: ViewModifier {
    let chrome: Chrome

    static var isShown: Bool {
        #if DEBUG
            !ChatBenchmarkAutoRun.isTranscriptOnly
        #else
            true
        #endif
    }

    func body(content: Content) -> some View {
        if Self.isShown {
            content.modifier(chrome)
        } else {
            content
        }
    }
}
