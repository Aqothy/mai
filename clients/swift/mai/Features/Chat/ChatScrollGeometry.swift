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
}
