import CoreGraphics
import Foundation

/// Compact saved scroll position for a closed transcript (PLAN 3.9 rule 9).
/// Stored on `ThreadSession` only while scrolled away from the end so a
/// switched-away thread reopens where the reader left off without retaining
/// controllers, layouts, or geometry buffers.
nonisolated struct TranscriptSavedPlace: Equatable, Sendable {
    let anchorID: String
    let offsetIntoRow: CGFloat
    let source: String
    let offsetIntoSource: CGFloat
    let expandedTurnIDs: Set<String>
}
