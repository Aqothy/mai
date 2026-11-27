import Foundation

/// A message of the transcript, of any kind (user, assistant, reasoning): its
/// Markdown is parsed whole off the main thread, and its kind decides only
/// presentation (a bubble, one row per top-level block, or muted text).
nonisolated struct TranscriptMessage: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case user
        case assistant
        case thought
    }

    let kind: Kind
    let turnID: String
    /// The entry's ref within its turn.
    let ref: String

    /// The message's ID: its rows' `sourceID`, and the key its parse is kept
    /// under.
    var id: String { "\(turnID)|\(ref)" }

    /// The ID of the one row the message shows as until it is parsed.
    var pendingRowID: String {
        switch kind {
        case .assistant: "\(id)#pending"
        case .user: "user|\(id)#pending"
        case .thought: "thought|\(id)#pending"
        }
    }

    static func parsedRowID(kind: Kind, id: String, at index: Int) -> String {
        switch kind {
        case .assistant: "\(id)#\(index)"
        case .user: "user|\(id)"
        case .thought: "thought|\(id)"
        }
    }

    func parsedRowID(at index: Int) -> String {
        Self.parsedRowID(kind: kind, id: id, at: index)
    }

    /// The message a Comment on its text belongs to: thoughts are no one's.
    var messageID: String? { kind == .thought ? nil : id }

    var role: TranscriptRole? {
        switch kind {
        case .user: .user
        case .assistant: .assistant
        case .thought: nil
        }
    }

    /// Produces the row kinds for a parsed message's `blocks` — strictly one
    /// row per top-level block with no slicing (`REDESIGN.md §7 R2`).
    static func rowKinds(for blocks: [MarkdownBlock], kind: Kind) -> [TranscriptRowKind] {
        switch kind {
        case .user:
            [.userMessage(blocks)]
        case .thought:
            [.thought(blocks)]
        case .assistant:
            blocks.enumerated().map { index, block in
                .markdownBlock(block, .of(index, in: blocks))
            }
        }
    }

    /// The row the message shows as until it is parsed.
    func pendingRow(source: String) -> TranscriptRow {
        TranscriptRow(
            id: pendingRowID, sourceID: id, kind: .pendingMessage(self, source: source),
            messageID: messageID, role: role, turnID: turnID)
    }

    /// Turns parsed Markdown `blocks` into this message's rows (one per
    /// top-level block for assistant messages; one bubble/thought row for user
    /// and reasoning).
    func rows(from blocks: [MarkdownBlock], metrics: [TextMetrics]? = nil) -> [TranscriptRow] {
        let kinds = Self.rowKinds(for: blocks, kind: kind)
        return kinds.indices.map { index in
            let rowMetrics = metrics.flatMap { index < $0.count ? $0[index] : nil }
            return TranscriptRow(
                id: parsedRowID(at: index), sourceID: id, kind: kinds[index],
                messageID: messageID, role: role, turnID: turnID, metrics: rowMetrics)
        }
    }
}
