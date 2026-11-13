import SwiftUI

nonisolated enum ChatContentMetrics {
    /// Keeps the transcript aligned with the composer and avoids reflowing
    /// readable text whenever surrounding navigation columns animate.
    static let maximumWidth: CGFloat = 760
}

nonisolated enum ChatTimelineMetrics {
    /// Hysteresis for follow state and the jump-to-bottom control. Native
    /// bottom alignment itself still pins to the exact content end.
    static let nearBottomDistance: CGFloat = 24
    static let rowVerticalInset: CGFloat = 10
    static let rowHorizontalInset: CGFloat = 16
    static let userBubbleHorizontalPadding: CGFloat = 14
    static let userBubbleVerticalPadding: CGFloat = 10
    static let interSegmentSpacing: CGFloat = 8
    static let historyMarkerHeight: CGFloat = 1

    static func rowWidth(in containerWidth: CGFloat) -> CGFloat {
        min(
            ChatContentMetrics.maximumWidth,
            max(0, containerWidth - 2 * rowHorizontalInset)
        )
    }

    static func proseTextWidth(role: String, in rowWidth: CGFloat) -> CGFloat {
        guard role == ChatRole.user.rawValue else { return rowWidth }
        return max(0, rowWidth - 2 * userBubbleHorizontalPadding)
    }
}
