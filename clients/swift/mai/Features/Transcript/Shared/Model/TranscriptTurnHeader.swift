import CoreGraphics
import Foundation

/// A turn's work header: "Working" while the turn runs, then the
/// "Worked for 42s" disclosure that folds its activity.
nonisolated struct TranscriptTurnHeader: Hashable, Sendable {
    let turnID: String
    let title: String
    let isRunning: Bool
    let isExpanded: Bool
    let hasFailure: Bool
}
