import SwiftUI

struct ChatScrollGeometry: Equatable {
    let isNearTop: Bool
    let isNearBottom: Bool
    let containerHeight: CGFloat
    let bottomInset: CGFloat
    let contentHeight: CGFloat
    let contentOffsetY: CGFloat
}

/// Handles explicit jump-to-bottom requests without storing a scroll proxy in
/// shared state. Automatic following is driven by post-layout geometry below.
struct ChatBottomScrollRequestModifier: ViewModifier {
    let scrollState: ChatScrollState
    let proxy: ScrollViewProxy
    let bottomID: String
    let pinToBottom: (_ animated: Bool) -> Bool

    func body(content: Content) -> some View {
        content.onChange(of: scrollState.bottomScrollRequest) { _, request in
            if pinToBottom(request.animated) {
                scrollState.noteEndVisibility(true)
                return
            }
            if request.animated {
                withAnimation(.smooth) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }
}

extension ScrollPhase {
    var isUserDriven: Bool {
        switch self {
        case .tracking, .interacting, .decelerating:
            true
        case .idle, .animating:
            false
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
