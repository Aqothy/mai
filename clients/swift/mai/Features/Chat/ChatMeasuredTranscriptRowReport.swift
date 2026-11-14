import Foundation

/// What a hosted row reports about its height. The revision is part of it:
/// `onGeometryChange` reports only a change, and a row given new content,
/// or a pooled view given another row, must report even at the height the
/// view last had, or a height measured offscreen that missed would stand.
nonisolated struct ChatMeasuredTranscriptRowReport: Equatable {
    let height: CGFloat
    let revision: Int
}
