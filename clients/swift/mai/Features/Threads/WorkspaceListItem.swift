import Foundation

/// Stable navigation identity for a Threads-list row. Agent threads and
/// terminals stay separate domains; only presentation merges them.
enum WorkspaceItemID: Hashable {
    case agentThread(String)
    case terminal(String)
}

/// One presentation row of the unified Threads list. Merging happens here in
/// the presentation layer; terminal summaries are never converted into fake
/// thread entries.
enum WorkspaceListItem: Identifiable {
    case agentThread(ThreadListEntry)
    case terminal(TerminalSummary)

    var id: WorkspaceItemID {
        switch self {
        case .agentThread(let thread): .agentThread(thread.id)
        case .terminal(let summary): .terminal(summary.terminalID)
        }
    }

    var updatedAt: Date {
        switch self {
        case .agentThread(let thread): thread.updatedAt
        case .terminal(let summary): summary.updatedAt
        }
    }

    /// Merges both domains into one deterministic list: updatedAt
    /// descending, with a stable id tiebreak so equal timestamps cannot
    /// reorder between updates.
    static func merged(
        threads: [ThreadListEntry],
        terminals: [TerminalSummary]
    ) -> [WorkspaceListItem] {
        var items = threads.map(WorkspaceListItem.agentThread)
        items.append(contentsOf: terminals.map(WorkspaceListItem.terminal))
        items.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.sortKey < rhs.sortKey
        }
        return items
    }

    private var sortKey: String {
        switch self {
        case .agentThread(let thread): thread.id
        case .terminal(let summary): summary.terminalID
        }
    }
}

/// What a terminal navigation destination should open.
enum TerminalOpenRequest: Hashable {
    case existing(terminalID: String)
    case new(cwd: String, title: String?)
}
