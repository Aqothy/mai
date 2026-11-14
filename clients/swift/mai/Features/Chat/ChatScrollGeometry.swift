import Foundation

/// What the transcript reports about its viewport after layout. Values are
/// rounded so sub-point noise does not publish a change.
struct ChatScrollGeometry: Equatable {
    let isNearTop: Bool
    let isNearBottom: Bool
    let containerWidth: CGFloat
    let containerHeight: CGFloat
    let bottomInset: CGFloat
    let contentHeight: CGFloat

    /// The scroll offset that shows the content's end just above the bottom
    /// inset, or, for content shorter than the viewport, its start just
    /// below the top inset.
    nonisolated static func bottomOffset(
        contentHeight: CGFloat, viewportHeight: CGFloat,
        topInset: CGFloat, bottomInset: CGFloat
    ) -> CGFloat {
        max(-topInset, contentHeight + bottomInset - viewportHeight)
    }
}
