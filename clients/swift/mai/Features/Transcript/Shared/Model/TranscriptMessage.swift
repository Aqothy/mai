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

    /// Turns parsed Markdown `blocks` into this message's rows: one row per
    /// block for assistant messages; one bubble row for user messages; one
    /// muted Markdown row for thoughts. Pass precomputed `metrics` (counted
    /// off-main) so rebuilding rows on the main thread never scans text.
    func rows(from blocks: [MarkdownBlock], metrics: [TextMetrics]? = nil) -> [TranscriptRow] {
        switch kind {
        case .assistant:
            return blocks.indices.map { index in
                let rowMetrics = metrics.flatMap { index < $0.count ? $0[index] : nil }
                return TranscriptRow(
                    id: "\(id)#\(index)", sourceID: id,
                    kind: .markdownBlock(blocks[index], .of(index, in: blocks)),
                    messageID: id, role: .assistant, turnID: turnID, metrics: rowMetrics)
            }
        case .user:
            let rowMetrics = metrics?.first
            return [
                TranscriptRow(
                    id: "user|\(id)", sourceID: id, kind: .userMessage(blocks),
                    messageID: id, role: .user, turnID: turnID, metrics: rowMetrics)
            ]
        case .thought:
            let rowMetrics = metrics?.first
            return [
                TranscriptRow(
                    id: "thought|\(id)", sourceID: id, kind: .thought(blocks),
                    messageID: nil, role: nil, turnID: turnID, metrics: rowMetrics)
            ]
        }
    }
}
