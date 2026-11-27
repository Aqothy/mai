import SwiftUI

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
