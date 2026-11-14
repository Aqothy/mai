import SwiftUI

/// Handles explicit jump-to-bottom requests. Automatic following is driven
/// by the transcript's own geometry.
struct ChatBottomScrollRequestModifier: ViewModifier {
    let scrollState: ChatScrollState
    /// Returns false while the transcript has no rows to scroll to; its
    /// first rows then land on the end by themselves.
    let pinToBottom: (_ animated: Bool) -> Bool

    func body(content: Content) -> some View {
        content.onChange(of: scrollState.bottomScrollRequest) { _, request in
            if pinToBottom(request.animated) {
                scrollState.noteEndVisibility(true)
            }
        }
    }
}

struct ChatEndMarker: View {
    var body: some View {
        Color.clear
            .frame(height: 24)
            .allowsHitTesting(false)
    }
}

struct ChatScrollToBottomButton: View {
    let scrollState: ChatScrollState
    let scrollToBottom: () -> Void

    var body: some View {
        ZStack {
            if !scrollState.isNearBottom {
                Button {
                    scrollToBottom()
                } label: {
                    Label("Scroll to bottom", systemImage: "arrow.down")
                        .labelStyle(.iconOnly)
                        .font(.body.bold())
                        .frame(width: 24, height: 24)
                        .contentShape(.circle)
                }
                .glassCircleButton()
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: scrollState.isNearBottom)
    }
}
