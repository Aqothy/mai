import Foundation

/// The transcript's rows from its turns, by the chat's rules:
/// - user messages and each turn's final assistant message always show;
/// - a finished turn folds its work (activity, thoughts, intermediate
///   messages, answered requests) behind one "Worked for …" header until
///   the reader expands it; a running turn shows everything, under a
///   "Working" header from its start;
/// - warnings, errors, messages between agents and running background tasks
///   never fold;
/// - consecutive activity entries share one summary row;
/// - a finished turn ends with its actions; a running chat ends with the
///   working row.
/// An assistant message is one row per Markdown block once parsed, and one
/// estimated row until then.
nonisolated struct TranscriptBuilder {
    /// Blocks for a message, if parsed or streaming: `(messageID, source)`.
    let blocks: (String, String) -> [MarkdownBlock]?
    /// Precomputed per-row text metrics for a parsed message, so rebuilding
    /// rows on the main thread never scans text.
    var metrics: (String) -> [TextMetrics]? = { _ in nil }
    /// Whether `messageID` has non-empty live streamed blocks (covers a
    /// streaming reasoning entry whose initial snapshot text was whitespace).
    var hasStreamedBlocks: (String) -> Bool = { _ in false }
    let expandedTurnIDs: Set<String>
    /// The working row's verb.
    let workingPhrase: String
    /// The thread's current plan checklist, shown as a notice row when present.
    var plan: [PlanEntry] = []

    private enum Item {
        case user(TranscriptEntry)
        case message(TranscriptEntry)
        case thought(TranscriptEntry)
        case activity([TranscriptEntry])
        case notice(ref: String, title: String, text: String?)
    }

    private struct Block {
        var item: Item
        var isFoldable: Bool
    }

    func rows(for turns: [TranscriptTurn]) -> [TranscriptRow] {
        rows(for: turns[...], hasRunningTurn: turns.contains(where: \.isRunning))
    }

    /// Builds rows for a contiguous slice of turns (used by incremental store
    /// updates to rebuild only modified tail turns).
    func rows(for turns: ArraySlice<TranscriptTurn>, hasRunningTurn: Bool) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(turns.count * 8)
        for turn in turns { append(turn, to: &rows) }
        if !plan.isEmpty {
            let checklist = plan.map { entry in
                let mark = entry.status == "completed" ? "✓" : "○"
                return "\(mark) \(entry.content)"
            }.joined(separator: "\n")
            rows.append(TranscriptRow(id: "plan", kind: .notice(title: "Plan", text: checklist)))
        }
        if hasRunningTurn {
            rows.append(TranscriptRow(id: "working", kind: .working(phrase: workingPhrase)))
        }
        return rows
    }

    private func append(_ turn: TranscriptTurn, to rows: inout [TranscriptRow]) {
        var blocks: [Block] = []
        for entry in turn.entries {
            switch entry.kind {
            case .userMessage:
                blocks.append(Block(item: .user(entry), isFoldable: false))
            case .assistantMessage:
                guard !entry.text.isEmpty else { continue }
                blocks.append(Block(item: .message(entry), isFoldable: true))
            case .reasoning:
                guard entry.text.contains(where: { !$0.isWhitespace }) || hasStreamedBlocks("\(turn.id)|\(entry.ref)")
                else {
                    continue
                }
                blocks.append(Block(item: .thought(entry), isFoldable: true))
            case .warning, .error:
                let title = entry.title ?? (entry.kind == .error ? "Error" : "Warning")
                blocks.append(Block(item: .notice(ref: entry.ref, title: title, text: entry.text), isFoldable: false))
            case .envelope:
                switch entry.envelopeKind {
                case .handoff:
                    blocks.append(
                        Block(
                            item: .notice(ref: entry.ref, title: "Continued from an earlier conversation", text: nil),
                            isFoldable: false))
                case .message, .reply, .notice:
                    let sender = entry.envelopeFrom.flatMap { $0.isEmpty ? nil : $0 } ?? "another agent"
                    let title: String =
                        switch entry.envelopeKind {
                        case .reply: "Reply from \(sender)"
                        case .notice: entry.title ?? "Notice"
                        default: "From \(sender)"
                        }
                    let body =
                        entry.envelopeBody.flatMap { $0.isEmpty ? nil : $0 }
                        ?? (entry.text.isEmpty ? nil : entry.text)
                    blocks.append(Block(item: .notice(ref: entry.ref, title: title, text: body), isFoldable: false))
                case .instructions, nil:
                    continue
                }
            case .request:
                guard entry.hasRequestRecord else { continue }
                blocks.append(Block(item: .notice(ref: entry.ref, title: entry.title ?? "Request", text: nil), isFoldable: true))
            default:
                if entry.isRunningInBackground {
                    blocks.append(Block(item: .activity([entry]), isFoldable: false))
                } else if !blocks.isEmpty, blocks[blocks.count - 1].isFoldable,
                    case .activity(var group) = blocks[blocks.count - 1].item
                {
                    // Drop the array reference inside `blocks` before appending
                    // so `group` stays uniquely referenced (avoids O(n²) COW).
                    blocks[blocks.count - 1].item = .activity([])
                    group.append(entry)
                    blocks[blocks.count - 1].item = .activity(group)
                } else {
                    blocks.append(Block(item: .activity([entry]), isFoldable: true))
                }
            }
        }

        let isExpanded = expandedTurnIDs.contains(turn.id)
        let showsFolded = turn.isRunning || isExpanded
        let finalMessage = blocks.lastIndex {
            if case .message = $0.item { return $0.isFoldable }
            return false
        }
        let header = TranscriptRow(
            id: "header|\(turn.id)",
            kind: .turnHeader(
                TranscriptTurnHeader(
                    turnID: turn.id, title: turn.isRunning ? "Working" : turn.workTitle, isRunning: turn.isRunning,
                    isExpanded: isExpanded)),
            turnID: turn.id)
        var didAddHeader = false
        for (index, block) in blocks.enumerated() {
            if block.isFoldable, index != finalMessage {
                if !didAddHeader {
                    didAddHeader = true
                    rows.append(header)
                }
                if showsFolded { append(block.item, turnID: turn.id, to: &rows) }
            } else {
                append(block.item, turnID: turn.id, to: &rows)
            }
        }
        if turn.isRunning, !didAddHeader { rows.append(header) }
        if turn.state == .interrupted, let error = turn.error, !error.isEmpty {
            rows.append(TranscriptRow(id: "stop|\(turn.id)", kind: .notice(title: error, text: nil), turnID: turn.id))
        }
        if turn.state?.isSettled == true {
            let hasReply = turn.entries.contains { $0.kind == .assistantMessage && !$0.text.isEmpty }
            rows.append(
                TranscriptRow(
                    id: "actions|\(turn.id)",
                    kind: .turnActions(turnID: turn.id, hasReply: hasReply),
                    turnID: turn.id))
        }
    }

    private func append(_ item: Item, turnID: String, to rows: inout [TranscriptRow]) {
        switch item {
        case .user(let entry):
            appendMessage(TranscriptMessage(kind: .user, turnID: turnID, ref: entry.ref), source: entry.text, to: &rows)
        case .message(let entry):
            appendMessage(
                TranscriptMessage(kind: .assistant, turnID: turnID, ref: entry.ref), source: entry.text, to: &rows)
        case .thought(let entry):
            appendMessage(
                TranscriptMessage(kind: .thought, turnID: turnID, ref: entry.ref), source: entry.text, to: &rows)
        case .activity(let entries):
            guard let first = entries.first else { return }
            rows.append(
                TranscriptRow(
                    id: "activity|\(turnID)|\(first.ref)",
                    kind: .activity(summary: TranscriptActivityPhrase.summary(entries.map(\.activityPhrase))),
                    turnID: turnID))
        case .notice(let ref, let title, let text):
            rows.append(
                TranscriptRow(id: "notice|\(turnID)|\(ref)", kind: .notice(title: title, text: text), turnID: turnID))
        }
    }

    private func appendMessage(_ message: TranscriptMessage, source: String, to rows: inout [TranscriptRow]) {
        guard let blocks = blocks(message.id, source) else {
            rows.append(message.pendingRow(source: source))
            return
        }
        rows.append(contentsOf: message.rows(from: blocks, metrics: metrics(message.id)))
    }
}
