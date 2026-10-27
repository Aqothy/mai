import Foundation

/// Builds the flat row list the chat `List` renders from a thread's turns.
///
/// Each turn is one section, in the daemon's order. Layout rules:
/// - User messages and the turn's final assistant message are always visible.
/// - Reasoning renders as plain dimmed text rows, not as steps among tools.
/// - Consecutive activity entries (tools, commands, file changes) merge into
///   one compact `ChatActivityGroup`.
/// - A settled turn folds everything else — activity, thoughts, and
///   intermediate assistant segments — behind a single `ChatTurnActivity`
///   header row ("Worked for 42s") until the user expands that section.
/// - The running turn's content is always visible.
/// - Warnings, errors, open requests, what other agents said, and running
///   background tasks never fold.
/// - A settled turn ends with its fork actions.
nonisolated enum ChatTimelineLayout {
    /// Emits rows from projected sections. Requests still open show at the
    /// end of their turn's section, those of no loaded turn at the end.
    /// `liveTurnID` keeps a turn that just settled presented as running
    /// until its settled rows are prepared.
    static func rows(
        sections: [Section],
        requests: [ChatRequest] = [],
        liveTurnID: String? = nil,
        expandedSectionIDs: Set<String>
    ) -> [ChatTimelineRowModel] {
        var requestsByTurn: [String: [ChatRequest]] = [:]
        var unplaced: [ChatRequest] = []
        let loadedTurns = Set(sections.map(\.id))
        // A request's record joins its turn just before the request leaves
        // the open ones.
        let recorded = Set(sections.flatMap { section in
            section.blocks.compactMap { block -> String? in
                if case .request(let request) = block.row { return request.id }
                return nil
            }
        })
        for request in requests where !recorded.contains(request.id) {
            if let turnID = request.turnID, loadedTurns.contains(turnID) {
                requestsByTurn[turnID, default: []].append(request)
            } else {
                unplaced.append(request)
            }
        }
        var rows: [ChatTimelineRowModel] = []
        for section in sections {
            appendRows(
                for: section,
                into: &rows,
                isRunning: section.isRunning || section.id == liveTurnID,
                isExpanded: expandedSectionIDs.contains(section.id)
            )
            rows.append(contentsOf: (requestsByTurn[section.id] ?? []).map(ChatTimelineRowModel.request))
            // Any settled turn forks; one a prompt started also edits it.
            if section.turn.turnState?.isSettled == true {
                rows.append(.turnFork(ChatTurnFork(turnID: section.id, prompt: section.prompt)))
            }
        }
        rows.append(contentsOf: unplaced.map(ChatTimelineRowModel.request))
        return rows
    }

    // MARK: Sections

    /// One turn's rows, before folding.
    struct Section {
        /// The turn's ID.
        var id: String
        /// The turn without its entries, which the blocks carry.
        var turn: TurnView
        var blocks: [Block] = []
        /// The prompt that started the turn.
        var prompt: ChatMessage?

        var isRunning: Bool { turn.turnState == .running }
    }

    /// A section entry tagged with whether it can hide behind the turn fold.
    struct Block {
        var row: ChatTimelineRowModel
        var isFoldable: Bool
    }

    static func section(for turn: TurnView) -> Section {
        var header = turn
        header.entries = []
        var section = Section(id: turn.id, turn: header)
        section.blocks.reserveCapacity(turn.entries.count)
        for entry in turn.entries {
            append(entry, of: turn.id, to: &section)
        }
        return section
    }

    static func sections(turns: [TurnView]) -> [Section] {
        turns.map(section(for:))
    }

    /// The newest sections holding up to `userMessageLimit` prompts; the
    /// first page of a long chat.
    static func paginatedSections<Sections: RandomAccessCollection>(
        _ sections: Sections,
        userMessageLimit: Int
    ) -> [Section] where Sections.Element == Section {
        guard userMessageLimit > 0 else { return [] }
        var remaining = userMessageLimit
        var startIndex = sections.endIndex
        while startIndex > sections.startIndex {
            startIndex = sections.index(before: startIndex)
            if sections[startIndex].prompt != nil {
                remaining -= 1
                if remaining == 0 { break }
            }
        }
        return Array(sections[startIndex...])
    }

    private static func append(_ entry: EntryView, of turnID: String, to section: inout Section) {
        switch entry.itemKind {
        case .userMessage:
            let message = ChatMessage(turnID: turnID, entry: entry)
            if section.prompt == nil { section.prompt = message }
            section.blocks.append(Block(row: .message(message), isFoldable: false))
        case .assistantMessage:
            // Empty segments would render as blank padded rows.
            guard entry.text?.isEmpty == false || entry.attachments?.isEmpty == false else { return }
            // Intermediate assistant segments fold with the activity; the
            // last one in the section is exempted at emission time.
            section.blocks.append(Block(row: .message(ChatMessage(turnID: turnID, entry: entry)), isFoldable: true))
        case .reasoning:
            section.blocks.append(Block(row: .thought(ChatItem(turnID: turnID, entry: entry)), isFoldable: true))
        case .warning, .error:
            section.blocks.append(Block(row: .notice(ChatItem(turnID: turnID, entry: entry)), isFoldable: false))
        case .envelope:
            switch entry.envelopeKind {
            case .handoff:
                section.blocks.append(Block(row: .handoff(ChatItem(turnID: turnID, entry: entry)), isFoldable: false))
            case .message, .reply, .notice:
                section.blocks.append(Block(row: .envelope(ChatItem(turnID: turnID, entry: entry)), isFoldable: false))
            case .instructions, nil:
                // A chat's instructions are for the agent; quotes show on
                // the message they annotate.
                break
            }
        case .request:
            guard let record = entry.request else { return }
            section.blocks.append(
                Block(row: .request(ChatRequest(record: record, turnID: turnID)), isFoldable: true)
            )
        default:
            let item = ChatItem(turnID: turnID, entry: entry)
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
                section.blocks[section.blocks.count - 1] = Block(row: .activityGroup(group), isFoldable: true)
            } else {
                section.blocks.append(
                    Block(row: .activityGroup(ChatActivityGroup(items: [item])), isFoldable: true)
                )
            }
        }
    }

    // MARK: Row emission

    private static func appendRows(
        for section: Section,
        into rows: inout [ChatTimelineRowModel],
        isRunning: Bool,
        isExpanded: Bool
    ) {
        let showsFoldedContent = isRunning || isExpanded
        let finalMessageIndex = section.blocks.lastIndex { block in
            if case .message = block.row { return block.isFoldable }
            return false
        }
        var didInsertHeader = false
        let header = ChatTimelineRowModel.turnActivity(
            turnActivity(for: section, isRunning: isRunning, isExpanded: isExpanded)
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
        // A running turn shows its header from the start, before its first
        // tool call or thought.
        if isRunning && !didInsertHeader {
            rows.append(header)
        }
    }

    private static func turnActivity(for section: Section, isRunning: Bool, isExpanded: Bool) -> ChatTurnActivity {
        var stepCount = 0
        var hasFailure = false
        var wasInterrupted = section.turn.turnState == .interrupted
        for block in section.blocks where block.isFoldable {
            switch block.row {
            case .activityGroup(let group):
                stepCount += group.items.count
                hasFailure = hasFailure || group.hasFailure
                wasInterrupted = wasInterrupted || group.items.contains { $0.itemStatus == .interrupted }
            case .request:
                stepCount += 1
            default:
                break
            }
        }
        return ChatTurnActivity(
            sectionID: section.id,
            stepCount: stepCount,
            duration: isRunning ? nil : duration(of: section.turn),
            isRunning: isRunning,
            startedAt: isRunning ? section.turn.startedAt : nil,
            isExpanded: isExpanded,
            hasFailure: hasFailure,
            wasInterrupted: wasInterrupted
        )
    }

    private static func duration(of turn: TurnView) -> Duration? {
        guard let settledAt = turn.settledAt else { return nil }
        let interval = settledAt.timeIntervalSince(turn.startedAt)
        guard interval >= 1 else { return nil }
        return .seconds(interval)
    }

    /// Streamed reasoning often carries leading/trailing newlines that would
    /// render as blank space, so the text is trimmed.
    static func reasoningText(_ item: ChatItem) -> String? {
        let trimmed = (item.entry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Who a chat message is from.
nonisolated enum ChatRole: String {
    case user
    case assistant
}

/// A user or assistant message of a turn.
nonisolated struct ChatMessage: Identifiable {
    let turnID: String
    var entry: EntryView

    /// Unique in the chat: refs are unique only within a session.
    var id: String { "\(turnID)|\(entry.ref)" }
    var role: String { entry.itemKind == .userMessage ? ChatRole.user.rawValue : ChatRole.assistant.rawValue }
    var text: String { entry.text ?? "" }
    var attachments: [Attachment]? { entry.attachments }
    var annotations: [PromptAnnotation]? { entry.annotations }
}

/// Any other entry of a turn: a tool call, a thought, a notice, a message
/// between agents.
nonisolated struct ChatItem: Identifiable {
    let turnID: String
    var entry: EntryView

    var id: String { "\(turnID)|\(entry.ref)" }
    var ref: String { entry.ref }
    var kind: String { entry.kind }
    var itemKind: MaidItemKind? { entry.itemKind }
    var itemStatus: MaidItemStatus? { entry.itemStatus }
    var title: String? { entry.title }
    var text: String? { entry.text }
    var tool: ToolCallSummary? { entry.tool }
    var detailAvailable: Bool { entry.detailAvailable == true }

    /// A background task its provider can stop, still running.
    var isRunningInBackground: Bool {
        itemStatus == .inProgress && tool?.background == true
    }
}

/// An agent's request: open, from the thread's requests, or answered, from
/// its record in the turn.
nonisolated struct ChatRequest: Identifiable {
    let id: String
    let ask: Request
    let turnID: String?
    /// Whether it still waits for an answer.
    let isOpen: Bool
    /// The action chosen: by the answer, or, while open, the one an answer
    /// chose that the agent hasn't taken yet.
    let actionID: String?
    let answers: [String: [String]]?

    init(open request: RequestView) {
        id = request.id
        ask = request.ask
        turnID = request.turn
        isOpen = true
        actionID = request.answering
        answers = nil
    }

    init(record: RequestRecord, turnID: String) {
        id = record.request
        ask = record.ask
        self.turnID = turnID
        isOpen = false
        actionID = record.action
        answers = record.answers
    }
}

/// One rendered row in the chat timeline.
nonisolated enum ChatTimelineRowModel: Identifiable {
    case message(ChatMessage)
    case thought(ChatItem)
    case turnActivity(ChatTurnActivity)
    case activityGroup(ChatActivityGroup)
    case notice(ChatItem)
    case request(ChatRequest)
    /// The conversation an agent was handed as text: a fork's, or what it
    /// missed while another agent worked.
    case handoff(ChatItem)
    /// What another agent or maiD said to this one.
    case envelope(ChatItem)
    case turnFork(ChatTurnFork)

    var id: String {
        switch self {
        case .message(let message): "message-\(message.id)"
        case .thought(let item): "thought-\(item.id)"
        case .turnActivity(let activity): activity.id
        case .activityGroup(let group): group.id
        case .notice(let item): "notice-\(item.id)"
        case .request(let request): "request-\(request.id)"
        case .handoff(let item): "handoff-\(item.id)"
        case .envelope(let item): "envelope-\(item.id)"
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

/// A run of consecutive activity entries rendered as one compact line.
nonisolated struct ChatActivityGroup: Identifiable {
    var items: [ChatItem]

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

/// What a provider stated about one activity entry, used to summarize
/// groups. Only stated facts count: the entry kind, or a read/search action
/// the provider declared. Any other tool is identified by its raw name.
nonisolated enum ChatActivityVerb: Equatable {
    case thought
    case read
    case searched
    case edited
    case ranCommand
    /// A tool with no stated action, by its raw (namespaced) name.
    case tool(String)

    init(item: ChatItem) {
        let summary = item.tool
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
    /// server, for example), falling back to the entry title and kind.
    private static func toolName(summary: ToolCallSummary?, item: ChatItem) -> String {
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

    /// The phrase for one or more such entries, without counts. `leading`
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

extension MaidTurnState {
    nonisolated var isSettled: Bool { self != .running }
}

extension ChatTimelineLayout.Block {
    fileprivate nonisolated var activityGroup: ChatActivityGroup? {
        if case .activityGroup(let group) = row { return group }
        return nil
    }
}
