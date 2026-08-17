import Foundation

struct ThreadListFilter: Equatable {
    var query = ""
    var projectCwd: String?
    /// Provider instance identifier to match. nil matches every provider.
    var providerID: String?

    var hasActivePresets: Bool {
        projectCwd != nil || providerID != nil
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isActive: Bool {
        hasActivePresets || !trimmedQuery.isEmpty
    }

    mutating func resetPresets() {
        projectCwd = nil
        providerID = nil
    }

    func apply(
        to threads: [ThreadListEntry],
        providerID providerIDForThread: (ThreadListEntry) -> String?
    ) -> [ThreadListEntry] {
        let query = trimmedQuery
        return threads.filter { thread in
            (projectCwd == nil || thread.cwd == projectCwd)
                && (providerID == nil || providerIDForThread(thread) == providerID)
                && (query.isEmpty || thread.title.localizedStandardContains(query))
        }
    }

    /// Filters terminal rows for the unified Threads list. Provider filters
    /// describe agent threads, so selecting one hides terminals.
    func apply(toTerminals terminals: [TerminalSummary]) -> [TerminalSummary] {
        guard providerID == nil else { return [] }
        let query = trimmedQuery
        return terminals.filter { terminal in
            (projectCwd == nil || terminal.cwd == projectCwd)
                && (query.isEmpty
                    || terminal.displayTitle.localizedStandardContains(query)
                    || terminal.observedTitle?.localizedStandardContains(query) == true)
        }
    }
}
