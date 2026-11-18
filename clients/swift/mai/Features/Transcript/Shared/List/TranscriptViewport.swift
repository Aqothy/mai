import CoreGraphics
import Foundation

/// The transcript's visible area: its size and the parts of it bars, the
/// composer or the keyboard cover. A change to any of these is layout, not
/// the reader (PLAN 3.9 rule 3).
nonisolated struct TranscriptViewport: Equatable, Sendable {
    var size: CGSize
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    /// The height of the uncovered part.
    var visibleHeight: CGFloat { max(0, size.height - topInset - bottomInset) }
}
