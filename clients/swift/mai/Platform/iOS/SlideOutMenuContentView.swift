import SwiftUI

struct SlideOutMenuContentView<Content: View>: View {
    let content: Content
    let progress: CGFloat
    let xOffset: CGFloat
    let close: () -> Void

    var body: some View {
        content
            .containerRelativeFrame(.horizontal)
            .frame(maxHeight: .infinity)
            .background(.background)
            .overlay {
                Color.gray.opacity(0.20 * progress)
                    .allowsHitTesting(false)
            }
            .overlay {
                Button(action: close) {
                    Color.clear
                        .contentShape(.rect)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .buttonStyle(.plain)
                .allowsHitTesting(progress > 0.001)
                .accessibilityHidden(progress <= 0.001)
                .accessibilityLabel("Close menu")
            }
            .clipShape(ContainerRelativeShape())
            .shadow(
                color: .black.opacity(0.22 * progress),
                radius: 24 * progress,
                x: -8 * progress
            )
            .offset(x: xOffset)
    }
}
