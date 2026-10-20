import Foundation

/// Builds the flat row list the chat `List` renders from the wire timeline.
///
/// The daemon appends timeline entries in canonical order and stamps a
/// `turnId` on every live item, message, and approval, so contiguous scanning
/// is enough to reconstruct turns. Restored history replays without turn ids;
/// those entries fall back to sections split on user messages.
///
/// A turn is not always contiguous: retrying a failed turn moves its prompt
/// onto the new turn, ahead of the failed turn's entries. One turn can then
/// span several sections, so a section is identified by its first entry,
/// never by its turn.
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
/// - Warnings, errors, pending approvals, undelivered messages, and running
///   background tasks never fold.
/// - A settled turn ends with its fork actions.
nonisolated enum ChatTimelineLayout {
    /// Emits rows from an already projected timeline. Keeping these sections
    /// as the List input prevents a live view from retaining the generated
    /// model's large `TimelineEntry` array while the store appends text to its
    /// last entry.
    static func rows(
        sections: [Section],
        streamingTurnID: String?,
        latestTurn: Turn?,
        previousTurns: [Turn] = [],
        expandedSectionIDs: Set<String>
    ) -> [ChatTimelineRowModel] {
        // Each section renders its own turn's outcome and timing, not only
        // the latest turn's.
        var turnsByID = Dictionary(
            previousTurns.map { ($0.turnID, $0) },
            uniquingKeysWith: { _, later in later }
        )
        if let latestTurn {
            turnsByID[latestTurn.turnID] = latestTurn
        }
        // Only the running turn's last section is live, so a split turn
        // shows one "Working" header.
        let runningSectionIndex = streamingTurnID.flatMap { streamingTurnID in
            sections.lastIndex { $0.turnID == streamingTurnID }
        }
        var rows: [ChatTimelineRowModel] = []
        var pendingHeader: ChatTimelineRowModel?
        let prompts = prompts(in: sections)
        var lastSectionIndexByTurnID: [String: Int] = [:]
        for (index, section) in sections.enumerated() {
            if let turnID = section.turnID {
                lastSectionIndexByTurnID[turnID] = index
            }
        }
        for (index, section) in sections.enumerated() {
            let turn = section.turnID.flatMap { turnsByID[$0] }
            if let header = appendRows(
                for: section,
                into: &rows,
                isRunning: index == runningSectionIndex,
                turn: turn,
                isExpanded: expandedSectionIDs.contains(section.id)
            ) {
                pendingHeader = header
            }
            // A turn split by a retry forks after its last section.
            if let turn, turn.completedAt != nil, lastSectionIndexByTurnID[turn.turnID] == index {
                rows.append(.turnFork(ChatTurnFork(turnID: turn.turnID, prompt: prompts[turn.turnID])))
            }
        }
        if let pendingHeader {
            rows.append(pendingHeader)
        }
        return rows
    }

    /// The prompt that started each turn.
    private static func prompts(in sections: [Section]) -> [String: Message] {
        var prompts: [String: Message] = [:]
        for section in sections {
            for block in section.blocks {
                guard case .message(let message) = block.row,
                    message.role == MaidMessageRole.user.rawValue,
                    let turnID = message.turnID, prompts[turnID] == nil
                else { continue }
                prompts[turnID] = message
            }
        }
        return prompts
    }

    // MARK: Sections

    /// One turn's worth of contiguous timeline entries.
    struct Section {
        /// Derived from the first entry, which is unique in the timeline.
        var id: String
        var turnID: String?
        var blocks: [Block] = []
        var earliest: Date?
        var latest: Date?
        /// Entries projected into this section, so incremental projection
        /// (`ChatTimelineProjection`) knows where each section begins.
        var entryCount = 0
    }

    /// Folds one entry into the section list, opening a new section when the
    /// entry starts a new turn. Shared by full projection and by
    /// `ChatTimelineProjection`'s suffix reprojection, so both produce
    /// identical sections.
    static func project(_ entry: TimelineEntry, into sections: inout [Section]) {
        let turnID = entryTurnID(entry)
        let isUserMessage =
            entry.message?.role == MaidMessageRole.user.rawValue

        var startsNewSection = sections.isEmpty
        if let current = sections.last {
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
                Section(id: "section-\(entry.kind)-\(entryIdentity(entry))", turnID: turnID)
            )
        }

        var section = sections.removeLast()
        if section.turnID == nil {
            section.turnID = turnID
        }
        append(entry, to: &section)
        sections.append(section)
    }

    /// A section entry tagged with whether it can hide behind the turn fold.
    struct Block {
        var row: ChatTimelineRowModel
        var isFoldable: Bool
    }

    static func sections(timeline: [TimelineEntry]) -> [Section] {
        var sections: [Section] = []
        sections.reserveCapacity(timeline.count / 4 + 1)
        for entry in timeline {
            project(entry, into: &sections)
        }
        return sections
    }

    /// Returns the newest complete turn sections, counting sections that
    /// contain a user message as page boundaries. Any trailing activity-only
    /// sections stay attached to the newest page.
    static func paginatedSections<Sections: RandomAccessCollection>(
        _ sections: Sections,
        userMessageLimit: Int
    ) -> [Section] where Sections.Element == Section {
        guard userMessageLimit > 0 else { return [] }

        var remainingUserMessages = userMessageLimit
        var startIndex = sections.endIndex
        while startIndex > sections.startIndex {
            let candidateIndex = sections.index(before: startIndex)
            let section = sections[candidateIndex]
            startIndex = candidateIndex

            let containsUserMessage = section.blocks.contains { block in
                guard case .message(let message) = block.row else {
                    return false
                }
                return message.role == MaidMessageRole.user.rawValue
            }
            if containsUserMessage {
                remainingUserMessages -= 1
                if remainingUserMessages == 0 {
                    break
                }
            }
        }
        return Array(sections[startIndex...])
    }

    private static func append(_ entry: TimelineEntry, to section: inout Section) {
        section.entryCount += 1
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
            if message.messageDelivery == .notDelivered {
                section.blocks.append(Block(row: .undelivered(message), isFoldable: false))
            }
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
            case .forkContext:
                section.blocks.append(Block(row: .forkContext(item), isFoldable: false))
            case .reasoning:
                section.blocks.append(Block(row: .thought(item), isFoldable: true))
            default:
                // A background task can outlive its turn; while it runs it
                // stays in view on its own row, where it can be stopped.
                if item.isRunningInBackground {
                    section.blocks.append(
                        Block(row: .activityGroup(ChatActivityGroup(items: [item])), isFoldable: false)
                    )
                } else if section.blocks.last?.isFoldable == true,
                    var group = section.blocks.last?.activityGroup
                {
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

    /// Returns the running section's header when no activity placed it yet.
    private static func appendRows(
        for section: Section,
        into rows: inout [ChatTimelineRowModel],
        isRunning: Bool,
        turn: Turn?,
        isExpanded: Bool
    ) -> ChatTimelineRowModel? {
        let showsFoldedContent = isRunning || isExpanded
        let finalMessageIndex = section.blocks.lastIndex { block in
            if case .message = block.row { return block.isFoldable }
            return false
        }
        var didInsertHeader = false
        let header = ChatTimelineRowModel.turnActivity(
            turnActivity(
                for: section,
                turn: turn,
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
        // first tool call or thought arrives. It ends the transcript, below
        // any older entries that follow the turn's prompt, such as the failed
        // attempt a retry continues from.
        return isRunning && !didInsertHeader ? header : nil
    }

    private static func turnActivity(
        for section: Section,
        turn: Turn?,
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
        if turn?.turnState == .interrupted {
            wasInterrupted = true
        }
        return ChatTurnActivity(
            sectionID: section.id,
            stepCount: stepCount,
            duration: isRunning ? nil : sectionDuration(section, turn: turn),
            isRunning: isRunning,
            startedAt: isRunning ? turn?.startedAt ?? turn?.requestedAt : nil,
            isExpanded: isExpanded,
            hasFailure: hasFailure,
            wasInterrupted: wasInterrupted
        )
    }

    /// A turn's authoritative timestamps give its duration. Without them,
    /// such as restored history re-stamped at replay time, the span falls
    /// back to entry timestamps, which genuinely may have no duration to show.
    private static func sectionDuration(
        _ section: Section,
        turn: Turn?
    ) -> Duration? {
        var interval: TimeInterval?
        if let turn, let completedAt = turn.completedAt {
            interval = completedAt.timeIntervalSince(turn.startedAt ?? turn.requestedAt)
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
    /// Why a message never reached the agent, under that message.
    case undelivered(Message)
    case thought(Item)
    case turnActivity(ChatTurnActivity)
    case activityGroup(ChatActivityGroup)
    case notice(Item)
    case approval(Approval)
    /// The conversation a fork handed its agent as text.
    case forkContext(Item)
    case turnFork(ChatTurnFork)

    var id: String {
        switch self {
        case .message(let message): "message-\(message.id)"
        case .undelivered(let message): "undelivered-\(message.id)"
        case .thought(let item): "thought-\(item.id)"
        case .turnActivity(let activity): activity.id
        case .activityGroup(let group): group.id
        case .notice(let item): "notice-\(item.id)"
        case .approval(let approval): "approval-\(approval.requestID)"
        case .forkContext(let item): "fork-context-\(item.id)"
        case .turnFork(let fork): fork.id
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

    /// At most this many distinct tool names appear before "+N more".
    static let maxToolNames = 3

    /// A phrase built only from what providers stated, such as
    /// "Read files, ran a command, WebFetch, github · list_issues".
    var summary: String {
        var counts: [(verb: ChatActivityVerb, count: Int)] = []
        for item in items {
            let verb = ChatActivityVerb(item: item)
            if let index = counts.firstIndex(where: { $0.verb == verb }) {
                counts[index].count += 1
            } else {
                counts.append((verb, 1))
            }
        }

        var phrases: [String] = []
        var toolNameCount = 0
        for (verb, count) in counts {
            if case .tool = verb {
                toolNameCount += 1
                guard toolNameCount <= Self.maxToolNames else { continue }
            }
            phrases.append(verb.phrase(count: count, leading: phrases.isEmpty))
        }
        if toolNameCount > Self.maxToolNames {
            phrases.append("+\(toolNameCount - Self.maxToolNames) more")
        }
        return phrases.joined(separator: ", ")
    }
}

/// What a provider stated about one activity item, used to summarize groups.
/// Only stated facts count: the item kind, or a read/search action the
/// provider declared. Any other tool is identified by its raw name.
nonisolated enum ChatActivityVerb: Equatable {
    case thought
    case read
    case searched
    case edited
    case ranCommand
    /// A tool with no stated action, by its raw (namespaced) name.
    case tool(String)

    init(item: Item) {
        let summary = item.toolCallSummary
        switch summary?.action.flatMap(MaidToolAction.init(rawValue:)) {
        case .read:
            self = .read
        case .search:
            self = .searched
        case nil:
            switch item.itemKind {
            case .reasoning: self = .thought
            case .commandExecution: self = .ranCommand
            case .fileChange: self = .edited
            default: self = .tool(Self.toolName(summary: summary, item: item))
            }
        }
    }

    /// The provider's own tool name, qualified by its namespace (an MCP
    /// server, for example), falling back to the item title and kind.
    private static func toolName(summary: ToolCallSummary?, item: Item) -> String {
        if let name = summary?.name, !name.isEmpty {
            if let namespace = summary?.namespace, !namespace.isEmpty {
                return "\(namespace) · \(name)"
            }
            return name
        }
        if let title = item.title, !title.isEmpty {
            return title
        }
        return item.kind
    }

    /// The phrase for one or more such items, without counts. `leading`
    /// capitalizes a verb that starts a sentence; raw tool names are never
    /// reformatted.
    func phrase(count: Int, leading: Bool = false) -> String {
        let text: String
        switch self {
        case .thought:
            text = "thought"
        case .read:
            text = count == 1 ? "read a file" : "read files"
        case .searched:
            text = "searched"
        case .edited:
            text = count == 1 ? "edited a file" : "edited files"
        case .ranCommand:
            text = count == 1 ? "ran a command" : "ran commands"
        case .tool(let name):
            return name
        }
        return leading ? text.prefix(1).uppercased() + text.dropFirst() : text
    }
}

extension Item {
    /// A background task its provider can stop, still running.
    nonisolated var isRunningInBackground: Bool {
        itemStatus == .inProgress && toolCallSummary?.background == true
    }
}

extension ChatTimelineLayout.Block {
    fileprivate nonisolated var activityGroup: ChatActivityGroup? {
        if case .activityGroup(let group) = row { return group }
        return nil
    }
}
