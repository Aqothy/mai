import CoreGraphics
import Foundation

/// Measured row and message heights for a thread at one column width and text
/// style, cached on `ThreadSession` so reopening a chat starts with exact
/// geometry and zero revisit height drift or scrollbar jump.
nonisolated struct TranscriptMeasuredHeights: Equatable, Sendable {
    let width: CGFloat
    let styleVersion: Int
    var rowHeights: [String: CGFloat]
    var sourceHeights: [String: CGFloat]
}
