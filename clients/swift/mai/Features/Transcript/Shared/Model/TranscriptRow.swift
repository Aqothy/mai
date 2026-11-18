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
    var kind: TranscriptRowKind
    var messageID: String?
    var role: TranscriptRole?
    /// Changes whenever the row's content does: a layout for another version
    /// is stale.
    var contentVersion: Int

    init(
        id: String, sourceID: String? = nil, kind: TranscriptRowKind,
        messageID: String? = nil, role: TranscriptRole? = nil, contentVersion: Int = 0
    ) {
        self.id = id
        self.sourceID = sourceID ?? id
        self.kind = kind
        self.messageID = messageID
        self.role = role
        self.contentVersion = contentVersion
    }
}
