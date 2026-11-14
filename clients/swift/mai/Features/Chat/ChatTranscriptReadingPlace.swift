import Foundation

/// Where a reader is in the transcript, in terms that outlast the rows
/// changing. The row being read can leave: a finished reply's live row
/// becomes its settled blocks, and a finished turn's work folds behind its
/// header.
nonisolated struct ChatTranscriptReadingPlace {
    /// The row being read, and how far into it the reader is.
    let anchor: ChatVirtualTranscriptGeometry.Anchor
    /// The content that row shows, and how far into all the rows showing
    /// it the reader is.
    let source: String
    let offsetIntoSource: CGFloat
    /// The rows above the anchor's when it was taken, nearest last. The
    /// arrays are the geometry's own, shared rather than copied.
    let idsAbove: ArraySlice<String>
    let sourcesAbove: ArraySlice<String>
}
