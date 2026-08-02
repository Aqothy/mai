import Foundation

/// Builds the flat row list the chat `List` renders from the wire timeline.
///
/// The daemon appends timeline entries in canonical order and stamps a
/// `turnId` on every live item, message, and approval, so contiguous scanning
/// is enough to reconstruct turns. Restored history replays without turn ids;
/// those entries fall back to sections split on user messages.
///
/// Layout rules:
/// - User messages and the turn's final assistant message are always visible.
/// - Reasoning renders as plain dimmed text rows, not as steps among tools.
/// - Consecutive activity items (tools, commands, file changes) merge into
///   one compact `ChatActivityGroup`.
/// - A finished turn folds everything else — activity, thoughts, and
///   intermediate assistant segments — behind a single `ChatTurnActivity`
///   header row ("Worked for 42s") until the user expands that section.
/// - The running turn's content is always visible.
/// - Warnings, errors, and pending approvals never fold.
nonisolated enum ChatTimelineLayout {
    static func rows(
        timeline: [TimelineEntry],
        streamingTurnID: String?,
        latestTurn: Turn?,
        expandedSectionIDs: Set<String>
    ) -> [ChatTimelineRowModel] {
        var rows: [ChatTimelineRowModel] = []
        for section in sections(timeline: timeline) {
            appendRows(
                for: section,
                into: &rows,
                streamingTurnID: streamingTurnID,
                latestTurn: latestTurn,
                isExpanded: expandedSectionIDs.contains(section.id)
            )
        }
        return rows
    }

    // MARK: Sections

    /// One turn's worth of contiguous timeline entries.
    struct Section {
        var id: String
        var turnID: String?
        var blocks: [Block] = []
        var earliest: Date?
        var latest: Date?
    }

    /// A section entry tagged with whether it can hide behind the turn fold.
    struct Block {
        var row: ChatTimelineRowModel
        var isFoldable: Bool
    }

    static func sections(timeline: [TimelineEntry]) -> [Section] {
        var sections: [Section] = []

        for entry in timeline {
            let turnID = entryTurnID(entry)
            let isUserMessage =
                entry.message?.role == MaidMessageRole.user.rawValue

            var startsNewSection = sections.isEmpty
            if let current = sections.last, !startsNewSection {
                if isUserMessage {
                    // A user message starts the next turn unless it was
                    // steering the turn this section already covers.
                    startsNewSection = turnID == nil || turnID != current.turnID
                } else if let turnID, let currentTurnID = current.turnID {
                    startsNewSection = turnID != currentTurnID
                }
            }

            if startsNewSection {
                sections.append(
                    Section(
                        id: turnID ?? "local-\(entryIdentity(entry))",
                        turnID: turnID
                    )
                )
            }

            var section = sections.removeLast()
            if section.turnID == nil {
                section.turnID = turnID
            }
            append(entry, to: &section)
            sections.append(section)
        }

        return sections
    }

    private static func append(_ entry: TimelineEntry, to section: inout Section) {
        switch entry.entryKind {
        case .message:
            guard let message = entry.message else { return }
            note(created: message.createdAt, updated: message.updatedAt, in: &section)
            // Empty segments would render as blank padded rows.
            guard !message.text.isEmpty || message.attachments?.isEmpty == false else {
                return
            }
            // Intermediate assistant segments fold with the activity; the
            // last one in the section is exempted at emission time.
            let isAssistant = message.role == MaidMessageRole.assistant.rawValue
            section.blocks.append(Block(row: .message(message), isFoldable: isAssistant))
        case .approval:
            guard let approval = entry.approval else { return }
            note(created: approval.createdAt, updated: approval.updatedAt, in: &section)
            // A resolved approval is part of the finished work; a pending one
            // needs the user's attention and must stay visible.
            let isResolved = approval.approvalStatus == .resolved
            section.blocks.append(
                Block(row: .approval(approval), isFoldable: isResolved)
            )
        case .item:
            guard let item = entry.item else { return }
            note(created: item.createdAt, updated: item.updatedAt, in: &section)
            switch item.itemKind {
            case .warning, .error:
                section.blocks.append(Block(row: .notice(item), isFoldable: false))
            case .reasoning:
                section.blocks.append(Block(row: .thought(item), isFoldable: true))
            default:
                if var group = section.blocks.last?.activityGroup {
                    group.items.append(item)
                    section.blocks[section.blocks.count - 1] =
                        Block(row: .activityGroup(group), isFoldable: true)
                } else {
                    section.blocks.append(
                        Block(
                            row: .activityGroup(ChatActivityGroup(items: [item])),
                            isFoldable: true
                        )
                    )
                }
            }
        case nil:
            break
        }
    }

    private static func note(created: Date, updated: Date, in section: inout Section) {
        section.earliest = section.earliest.map { min($0, created) } ?? created
        section.latest = section.latest.map { max($0, updated) } ?? updated
    }

    // MARK: Row emission

    private static func appendRows(
        for section: Section,
        into rows: inout [ChatTimelineRowModel],
        streamingTurnID: String?,
        latestTurn: Turn?,
        isExpanded: Bool
    ) {
        let isRunning = streamingTurnID != nil && section.turnID == streamingTurnID
        let showsFoldedContent = isRunning || isExpanded
        let finalMessageIndex = section.blocks.lastIndex { block in
            if case .message = block.row { return block.isFoldable }
            return false
        }
        var didInsertHeader = false
        let header = ChatTimelineRowModel.turnActivity(
            turnActivity(
                for: section,
                latestTurn: latestTurn,
                isRunning: isRunning,
                isExpanded: isExpanded
            )
        )

        for (index, block) in section.blocks.enumerated() {
            if block.isFoldable, index != finalMessageIndex {
                if !didInsertHeader {
                    didInsertHeader = true
                    rows.append(header)
                }
                if showsFoldedContent {
                    rows.append(block.row)
                }
            } else {
                rows.append(block.row)
            }
        }

        // A running turn shows its header from the start, even before the
        // first tool call or thought arrives.
        if isRunning, !didInsertHeader {
            rows.append(header)
        }
    }

    private static func turnActivity(
        for section: Section,
        latestTurn: Turn?,
        isRunning: Bool,
        isExpanded: Bool
    ) -> ChatTurnActivity {
        var stepCount = 0
        var hasFailure = false
        var wasInterrupted = false
        for block in section.blocks where block.isFoldable {
            switch block.row {
            case .activityGroup(let group):
                stepCount += group.items.count
                hasFailure = hasFailure || group.hasFailure
                wasInterrupted = wasInterrupted
                    || group.items.contains { $0.itemStatus == .interrupted }
            case .approval:
                stepCount += 1
            default:
                break
            }
        }
        if latestTurn?.turnID == section.turnID,
            latestTurn?.turnState == .interrupted
        {
            wasInterrupted = true
        }
        return ChatTurnActivity(
            sectionID: section.id,
            stepCount: stepCount,
            duration: isRunning ? nil : sectionDuration(section, latestTurn: latestTurn),
            isRunning: isRunning,
            startedAt: isRunning && latestTurn?.turnID == section.turnID
                ? latestTurn?.startedAt ?? latestTurn?.requestedAt
                : nil,
            isExpanded: isExpanded,
            hasFailure: hasFailure,
            wasInterrupted: wasInterrupted
        )
    }

    /// The latest turn keeps authoritative timestamps; older turns are gone
    /// from the wire model, so their span is derived from entry timestamps.
    /// Restored history re-stamps entries at replay time, so those turns
    /// genuinely have no duration to show.
    private static func sectionDuration(
        _ section: Section,
        latestTurn: Turn?
    ) -> Duration? {
        var interval: TimeInterval?
        if let latestTurn,
            latestTurn.turnID == section.turnID,
            let completedAt = latestTurn.completedAt
        {
            interval = completedAt.timeIntervalSince(
                latestTurn.startedAt ?? latestTurn.requestedAt
            )
        } else if let earliest = section.earliest, let latest = section.latest {
            interval = latest.timeIntervalSince(earliest)
        }
        guard let interval, interval >= 1 else { return nil }
        return .seconds(interval)
    }

    // MARK: Entry projections

    static func entryTurnID(_ entry: TimelineEntry) -> String? {
        let turnID = entry.message?.turnID
            ?? entry.item?.turnID
            ?? entry.approval?.turnID
        return turnID?.isEmpty == false ? turnID : nil
    }

    private static func entryIdentity(_ entry: TimelineEntry) -> String {
        entry.message?.id
            ?? entry.item?.id
            ?? entry.approval?.requestID
            ?? entry.kind
    }

    /// `JSONAny` is main-actor isolated, so payload text extraction stays on
    /// the main actor; the layout pass itself never reads payloads.
    /// Streamed reasoning often carries leading/trailing newlines that would
    /// render as blank space, so the text is trimmed.
    @MainActor
    static func reasoningText(_ item: Item) -> String? {
        guard let text = (item.payload?.value as? [String: Any])?["text"] as? String
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One rendered row in the chat timeline.
nonisolated enum ChatTimelineRowModel: Identifiable {
    case message(Message)
    case thought(Item)
    case turnActivity(ChatTurnActivity)
    case activityGroup(ChatActivityGroup)
    case notice(Item)
    case approval(Approval)

    var id: String {
        switch self {
        case .message(let message): "message-\(message.id)"
        case .thought(let item): "thought-\(item.id)"
        case .turnActivity(let activity): activity.id
        case .activityGroup(let group): group.id
        case .notice(let item): "notice-\(item.id)"
        case .approval(let approval): "approval-\(approval.requestID)"
        }
    }
}

/// The turn's work header: a live "Working" timer while the turn runs, and
/// the folded "Worked for 42s" disclosure once it finishes.
nonisolated struct ChatTurnActivity: Identifiable, Equatable {
    let sectionID: String
    let stepCount: Int
    let duration: Duration?
    let isRunning: Bool
    let startedAt: Date?
    let isExpanded: Bool
    let hasFailure: Bool
    let wasInterrupted: Bool

    var id: String { "activity-\(sectionID)" }

    var title: String {
        if wasInterrupted {
            if let duration {
                return "Stopped after \(Self.formatted(duration))"
            }
            return "Stopped"
        }
        if let duration {
            return "Worked for \(Self.formatted(duration))"
        }
        return "Worked"
    }

    static func formatted(_ duration: Duration) -> String {
        let totalSeconds = Int(duration.components.seconds)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes == 0 { return "\(seconds)s" }
        if seconds == 0 { return "\(minutes)m" }
        return "\(minutes)m \(seconds)s"
    }
}

/// A run of consecutive activity items rendered as one compact line.
nonisolated struct ChatActivityGroup: Identifiable {
    var items: [Item]

    var id: String { "group-\(items.first?.id ?? "empty")" }

    var hasFailure: Bool {
        items.contains { $0.itemStatus == .failed }
    }

    var isInProgress: Bool {
        items.contains { $0.itemStatus == .inProgress }
    }

    /// A Codex-style phrase such as "Read 2 files, ran a command".
    var summary: String {
        var counts: [(verb: ChatActivityVerb, count: Int)] = []
        var toolName: String?
        for item in items {
            let verb = ChatActivityVerb(item: item)
            if verb == .tool, toolName == nil {
                toolName = item.toolCallSummary?.name ?? item.title
            }
            if let index = counts.firstIndex(where: { $0.verb == verb }) {
                counts[index].count += 1
            } else {
                counts.append((verb, 1))
            }
        }

        let phrases = counts.map { verb, count in
            verb.phrase(count: count, toolName: toolName)
        }
        guard let first = phrases.first else { return "" }
        return ([first.capitalizedFirst] + phrases.dropFirst())
            .joined(separator: ", ")
    }
}

/// Provider-neutral verb bucket used to summarize grouped activity.
nonisolated enum ChatActivityVerb: Equatable {
    case thought
    case read
    case searched
    case edited
    case ranCommand
    case fetched
    case tool

    init(item: Item) {
        switch item.itemKind {
        case .reasoning:
            self = .thought
            return
        case .commandExecution:
            self = .ranCommand
            return
        case .fileChange:
            self = .edited
            return
        default:
            break
        }
        switch item.toolCallSummary.flatMap({ MaidToolAction(rawValue: $0.action) }) {
        case .read, .view: self = .read
        case .search: self = .searched
        case .edit, .delete, .move: self = .edited
        case .execute: self = .ranCommand
        case .think: self = .thought
        case .fetch: self = .fetched
        default: self = .tool
        }
    }

    func phrase(count: Int, toolName: String?) -> String {
        switch self {
        case .thought:
            return "thought"
        case .read:
            return count == 1 ? "read a file" : "read \(count) files"
        case .searched:
            return count == 1 ? "searched" : "ran \(count) searches"
        case .edited:
            return count == 1 ? "edited a file" : "edited \(count) files"
        case .ranCommand:
            return count == 1 ? "ran a command" : "ran \(count) commands"
        case .fetched:
            return count == 1 ? "fetched a page" : "fetched \(count) pages"
        case .tool:
            if count == 1, let toolName, !toolName.isEmpty {
                return "used \(toolName)"
            }
            return count == 1 ? "used a tool" : "used \(count) tools"
        }
    }
}

extension ChatTimelineLayout.Block {
    fileprivate nonisolated var activityGroup: ChatActivityGroup? {
        if case .activityGroup(let group) = row { return group }
        return nil
    }
}

extension String {
    nonisolated var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
