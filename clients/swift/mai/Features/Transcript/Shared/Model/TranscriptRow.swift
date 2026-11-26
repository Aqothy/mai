import CoreGraphics
import Foundation

/// One row of the transcript: what it shows, the content it belongs to and
/// the message that owns it (for selection and Comment).
nonisolated struct TranscriptRow: Equatable, Sendable {
    let id: String
    /// The content the row shows. The rows one piece of content is split
    /// into share it, so the reading place survives a live reply becoming
    /// its final blocks (PLAN 3.9 rule 4).
    let sourceID: String
    let kind: TranscriptRowKind
    var messageID: String?
    var role: TranscriptRole?
    /// The turn this row belongs to, so incremental store updates rebuild only
    /// changed turns without rescanning history.
    var turnID: String?
    /// Precomputed text counts for O(1) height estimation on the main thread.
    let metrics: TextMetrics
    /// Changes whenever the row's content does: a layout for another version
    /// is stale.
    var contentVersion: Int

    init(
        id: String, sourceID: String? = nil, kind: TranscriptRowKind,
        messageID: String? = nil, role: TranscriptRole? = nil, turnID: String? = nil,
        metrics: TextMetrics? = nil, contentVersion: Int = 0
    ) {
        self.id = id
        self.sourceID = sourceID ?? id
        self.kind = kind
        self.messageID = messageID
        self.role = role
        self.turnID = turnID
        self.metrics = metrics ?? TextMetrics(kind)
        self.contentVersion = contentVersion
    }
}
