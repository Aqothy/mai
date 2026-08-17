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

    /// The project directory this item belongs to, or nil when it has none.
    var projectDirectory: String? {
        switch self {
        case .agentThread(let thread):
            guard let cwd = thread.cwd, !cwd.isEmpty else { return nil }
            return cwd
        case .terminal(let summary):
            return summary.cwd.isEmpty ? nil : summary.cwd
        }
    }
}

/// One project's worth of Threads-list rows.
struct WorkspaceListSection: Identifiable {
    /// The project's working directory; doubles as stable identity.
    let id: String
    let items: [WorkspaceListItem]

    var name: String {
        URL(filePath: id).lastPathComponent
    }
}

/// The Threads list grouped for the "By Project" display mode: items
/// without a project first, then one section per project directory.
struct WorkspaceListGroups {
    let ungrouped: [WorkspaceListItem]
    let projects: [WorkspaceListSection]

    /// Groups pre-merged rows (already updatedAt-descending). Section order
    /// follows each project's most recent activity, which is its first item
    /// thanks to the incoming sort; ties cannot reorder because grouping is
    /// insertion-ordered over a deterministic input.
    init(
        items: [WorkspaceListItem],
        projectDirectories: [String] = []
    ) {
        var ungrouped: [WorkspaceListItem] = []
        var itemsByProject: [String: [WorkspaceListItem]] = [:]
        var projectOrder: [String] = []

        for item in items {
            guard let projectDirectory = item.projectDirectory else {
                ungrouped.append(item)
                continue
            }
            if itemsByProject[projectDirectory] == nil {
                projectOrder.append(projectDirectory)
            }
            itemsByProject[projectDirectory, default: []].append(item)
        }

        // Explicitly added folders stay visible before their first thread.
        // Active project sections retain activity order; empty additions follow
        // in the user's most-recently-added order.
        for projectDirectory in projectDirectories
        where !projectDirectory.isEmpty && itemsByProject[projectDirectory] == nil {
            projectOrder.append(projectDirectory)
            itemsByProject[projectDirectory] = []
        }

        self.ungrouped = ungrouped
        self.projects = projectOrder.map { cwd in
            WorkspaceListSection(id: cwd, items: itemsByProject[cwd] ?? [])
        }
    }
}

/// What a terminal navigation destination should open.
enum TerminalOpenRequest: Hashable {
    case existing(terminalID: String)
    case new(cwd: String, title: String?)
}
