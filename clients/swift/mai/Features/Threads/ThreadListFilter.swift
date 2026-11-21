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

    /// Chats an agent started show under the chat that started them, so
    /// the list holds top-level chats only, unless a search looks for any.
    func apply(
        to threads: [ThreadSummary],
        providerID providerIDForThread: (ThreadSummary) -> String?
    ) -> [ThreadSummary] {
        let query = trimmedQuery
        return threads.filter { thread in
            (thread.origin.parent == nil || !query.isEmpty)
                && (projectCwd == nil || thread.workspace.cwd == projectCwd)
                && (providerID == nil || providerIDForThread(thread) == providerID)
                && (query.isEmpty || thread.title.localizedStandardContains(query))
        }
    }

    /// The filtered threads from the store.
    func apply(to store: ThreadStore) -> [ThreadSummary] {
        apply(to: store.threads, providerID: store.providerID(for:))
    }
}
