import CoreGraphics
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
    let expandedTurnIDs: Set<String>
    /// The working row's verb.
    let workingPhrase: String

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
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(turns.count * 8)
        for turn in turns { append(turn, to: &rows) }
        if turns.contains(where: \.isRunning) {
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
                    blocks.append(
                        Block(item: .notice(ref: entry.ref, title: entry.title ?? "Message", text: entry.text), isFoldable: false))
                case .instructions, nil:
                    continue
                }
            case .request:
                guard entry.hasRequestRecord else { continue }
                blocks.append(Block(item: .notice(ref: entry.ref, title: entry.title ?? "Request", text: nil), isFoldable: true))
            default:
                if entry.isRunningInBackground {
                    blocks.append(Block(item: .activity([entry]), isFoldable: false))
                } else if case .activity(var group)? = blocks.last?.item, blocks.last?.isFoldable == true {
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
                    isExpanded: isExpanded)))
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
            rows.append(TranscriptRow(id: "stop|\(turn.id)", kind: .notice(title: error, text: nil)))
        }
        if turn.state.map({ $0 != .running }) == true {
            let reply = turn.entries.filter { $0.kind == .assistantMessage && !$0.text.isEmpty }.map(\.text)
            rows.append(
                TranscriptRow(
                    id: "actions|\(turn.id)",
                    kind: .turnActions(turnID: turn.id, replyMarkdown: reply.joined(separator: "\n\n"))))
        }
    }

    private func append(_ item: Item, turnID: String, to rows: inout [TranscriptRow]) {
        switch item {
        case .user(let entry):
            let id = "\(turnID)|\(entry.ref)"
            rows.append(
                TranscriptRow(
                    id: "user|\(id)", sourceID: id, kind: .userMessage(source: entry.text), messageID: id, role: .user))
        case .message(let entry):
            let id = "\(turnID)|\(entry.ref)"
            guard let blocks = blocks(id, entry.text) else {
                rows.append(
                    TranscriptRow(
                        id: "\(id)#pending", sourceID: id, kind: .pendingMessage(source: entry.text), messageID: id,
                        role: .assistant))
                return
            }
            for (index, block) in blocks.enumerated() {
                rows.append(
                    TranscriptRow(
                        id: "\(id)#\(index)", sourceID: id,
                        kind: .markdownBlock(
                            block, .of(index, in: blocks)),
                        messageID: id, role: .assistant))
            }
        case .thought(let entry):
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            rows.append(TranscriptRow(id: "thought|\(turnID)|\(entry.ref)", kind: .thought(text)))
        case .activity(let entries):
            guard let first = entries.first else { return }
            rows.append(
                TranscriptRow(
                    id: "activity|\(turnID)|\(first.ref)",
                    kind: .activity(summary: TranscriptActivityPhrase.summary(entries.map(\.activityPhrase)))))
        case .notice(let ref, let title, let text):
            rows.append(TranscriptRow(id: "notice|\(turnID)|\(ref)", kind: .notice(title: title, text: text)))
        }
    }
}
