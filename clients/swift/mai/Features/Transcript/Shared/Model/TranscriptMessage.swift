import Foundation

/// A message of the transcript, of any kind (user, assistant, reasoning): its
/// Markdown is parsed whole off the main thread (`LayoutQueue`), and its kind
/// decides only presentation (a bubble, one row per block, or muted text).
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

    /// The ID of the message's first row once parsed.
    var firstParsedRowID: String {
        switch kind {
        case .assistant: "\(id)#0"
        case .user: "user|\(id)"
        case .thought: "thought|\(id)"
        }
    }

    /// Row ID for the `index`-th parsed row of this message. Preserves the
    /// single-row IDs `"user|\(id)"` and `"thought|\(id)"` for row 0 so saved
    /// places and pending-row lookups stay stable whether a message is 1 row
    /// or flattened into bounded slices.
    func parsedRowID(at index: Int) -> String {
        switch kind {
        case .assistant: "\(id)#\(index)"
        case .user: index == 0 ? "user|\(id)" : "user|\(id)#\(index)"
        case .thought: index == 0 ? "thought|\(id)" : "thought|\(id)#\(index)"
        }
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

    /// The row the message shows as until it is parsed: O(1) estimated height,
    /// blank until its off-main parse lands.
    func pendingRow(source: String) -> TranscriptRow {
        TranscriptRow(
            id: pendingRowID, sourceID: id, kind: .pendingMessage(self, source: source),
            messageID: messageID, role: role, turnID: turnID)
    }

    /// Turns parsed Markdown `blocks` into this message's bounded rows via
    /// `TranscriptBlockFlattener` (every prose unit `<= 8 KB` across user,
    /// assistant, and thought messages). Pass precomputed `metrics` (counted
    /// off-main) so rebuilding rows on the main thread never scans text.
    func rows(from blocks: [MarkdownBlock], metrics: [TextMetrics]? = nil) -> [TranscriptRow] {
        let kinds = TranscriptBlockFlattener.kinds(for: blocks, kind: kind)
        return kinds.indices.map { index in
            let rowMetrics = metrics.flatMap { index < $0.count ? $0[index] : nil }
            return TranscriptRow(
                id: parsedRowID(at: index), sourceID: id, kind: kinds[index],
                messageID: messageID, role: role, turnID: turnID, metrics: rowMetrics)
        }
    }
}
