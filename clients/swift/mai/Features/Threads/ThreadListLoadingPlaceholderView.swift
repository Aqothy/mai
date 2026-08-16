import SwiftUI

/// Skeleton rows shown while the thread-list snapshot loads. Row metrics
/// mirror ThreadRow so the list doesn't jump when real content lands.
struct ThreadListLoadingPlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SkeletonMetrics.titleFractions, id: \.self) { titleFraction in
                SkeletonRow(titleFraction: titleFraction)
                    .padding(SkeletonMetrics.insets)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .modifier(SkeletonPulse())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Chats")
    }
}

/// One two-line placeholder row: a body-font title capsule with a trailing
/// timestamp stub, over a caption-line capsule.
private struct SkeletonRow: View {
    let titleFraction: CGFloat

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: SkeletonMetrics.lineSpacing) {
                HStack {
                    Capsule()
                        .frame(
                            width: min(proxy.size.width * titleFraction, 240),
                            height: SkeletonMetrics.titleHeight
                        )
                    Spacer(minLength: 8)
                    Capsule()
                        .frame(width: 24, height: SkeletonMetrics.captionHeight)
                }
                Capsule()
                    .frame(
                        width: min(proxy.size.width * 0.42, 150),
                        height: SkeletonMetrics.captionHeight
                    )
            }
        }
        .frame(height: SkeletonMetrics.rowContentHeight)
        .foregroundStyle(.quaternary)
    }
}

/// A slow breathing dim, matching the system's placeholder shimmer cadence.
private struct SkeletonPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(isDimmed ? 0.45 : 1)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1).repeatForever(autoreverses: true),
                value: isDimmed
            )
            .onAppear { isDimmed = true }
    }
}

/// Sized against ThreadRow: the title capsule stands in for a body-font
/// line, the caption capsules for the caption line.
private enum SkeletonMetrics {
    // Fractions double as ForEach identity, so they must stay unique.
    static let titleFractions: [CGFloat] = [0.68, 0.46, 0.74, 0.38, 0.62, 0.52, 0.44]
    static let titleHeight: CGFloat = 14
    static let captionHeight: CGFloat = 10
    static let lineSpacing: CGFloat = 8
    static let insets = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)

    static var rowContentHeight: CGFloat {
        titleHeight + lineSpacing + captionHeight
    }
}

#if DEBUG
    #Preview("Thread List Loading Placeholder") {
        ThreadListLoadingPlaceholderView()
            .frame(width: 300)
    }
#endif
