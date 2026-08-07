import Foundation

enum ThreadListActivityFilter: String, CaseIterable, Identifiable {
    case all
    case unread
    case needsApproval
    case working

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Chats"
        case .unread: "Unread"
        case .needsApproval: "Needs Approval"
        case .working: "Working"
        }
    }
}

struct ThreadListFilter {
    var query = ""
    var projectCwd: String?
    /// Driver identifier to match, e.g. "claude", "codex", or "acp".
    /// nil matches every driver.
    var driver: String?
    var activityFilter: ThreadListActivityFilter = .all

    var hasActivePresets: Bool {
        projectCwd != nil || driver != nil || activityFilter != .all
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isActive: Bool {
        hasActivePresets || !trimmedQuery.isEmpty
    }

    mutating func resetPresets() {
        projectCwd = nil
        driver = nil
        activityFilter = .all
    }

    func apply(
        to threads: [ThreadListEntry],
        isUnread: (String) -> Bool,
        driver driverForThread: (ThreadListEntry) -> String?
    ) -> [ThreadListEntry] {
        let query = trimmedQuery
        return threads.filter { thread in
            (projectCwd == nil || thread.cwd == projectCwd)
                && (driver == nil || driverForThread(thread) == driver)
                && matchesActivity(thread, isUnread: isUnread)
                && (query.isEmpty || thread.title.localizedStandardContains(query))
        }
    }

    /// Filters terminal rows for the unified Threads list. Driver and
    /// activity presets describe agent threads, so any of them hides
    /// terminals; the query matches persisted and observed titles.
    func apply(toTerminals terminals: [TerminalSummary]) -> [TerminalSummary] {
        guard driver == nil, activityFilter == .all else { return [] }
        let query = trimmedQuery
        return terminals.filter { terminal in
            (projectCwd == nil || terminal.cwd == projectCwd)
                && (query.isEmpty
                    || terminal.displayTitle.localizedStandardContains(query)
                    || terminal.observedTitle?.localizedStandardContains(query) == true)
        }
    }

    private func matchesActivity(
        _ thread: ThreadListEntry,
        isUnread: (String) -> Bool
    ) -> Bool {
        switch activityFilter {
        case .all: true
        case .unread: isUnread(thread.id)
        case .needsApproval: thread.hasPendingApprovals
        case .working: thread.latestTurn?.turnState == .running
        }
    }
}
