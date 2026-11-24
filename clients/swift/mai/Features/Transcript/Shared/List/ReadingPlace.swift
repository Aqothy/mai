import CoreGraphics
import Foundation

/// Where a reader is, in terms that outlast the rows changing. The row being
/// read can leave: a live reply's rows become its final blocks, and a
/// finished turn's work folds behind its header (PLAN 3.9 rule 4).
nonisolated struct ReadingPlace: Sendable {
    /// The row at the viewport's top, and how far the top is into it;
    /// negative while the viewport rubber-bands above the first row.
    let anchorID: String
    let offsetIntoRow: CGFloat
    /// The content that row shows, and how far into all the rows showing it
    /// the reader is.
    let source: String
    let offsetIntoSource: CGFloat
    /// The rows above the anchor when the place was taken, nearest last.
    /// Copied (or empty when the anchor cannot be removed) so holding a
    /// `ReadingPlace` never shares `TranscriptGeometry`'s backing buffer and
    /// triggers copy-on-write during `replaceRows`.
    let idsAbove: [String]
    let sourcesAbove: [String]
}
