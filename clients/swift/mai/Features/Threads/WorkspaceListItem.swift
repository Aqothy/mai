import Foundation

/// One project's worth of Threads-list rows.
struct WorkspaceListSection: Identifiable {
    /// The project's working directory; doubles as stable identity.
    let id: String
    let threads: [ThreadSummary]

    var name: String {
        URL(filePath: id).lastPathComponent
    }
}

/// The Threads list grouped for the "By Project" display mode: threads
/// without a project first, then one section per project directory.
struct WorkspaceListGroups {
    let ungrouped: [ThreadSummary]
    let projects: [WorkspaceListSection]

    /// Groups pre-sorted threads (already updatedAt-descending). Section order
    /// follows each project's most recent activity, which is its first thread
    /// thanks to the incoming sort; ties cannot reorder because grouping is
    /// insertion-ordered over a deterministic input.
    init(
        threads: [ThreadSummary],
        projectDirectories: [String] = []
    ) {
        var ungrouped: [ThreadSummary] = []
        var threadsByProject: [String: [ThreadSummary]] = [:]
        var projectOrder: [String] = []

        for thread in threads {
            let projectDirectory = thread.workspace.cwd
            guard !projectDirectory.isEmpty else {
                ungrouped.append(thread)
                continue
            }
            if threadsByProject[projectDirectory] == nil {
                projectOrder.append(projectDirectory)
            }
            threadsByProject[projectDirectory, default: []].append(thread)
        }

        // Explicitly added folders stay visible before their first thread.
        // Active project sections retain activity order; empty additions follow
        // in the user's most-recently-added order.
        for projectDirectory in projectDirectories
        where !projectDirectory.isEmpty && threadsByProject[projectDirectory] == nil {
            projectOrder.append(projectDirectory)
            threadsByProject[projectDirectory] = []
        }

        self.ungrouped = ungrouped
        self.projects = projectOrder.map { cwd in
            WorkspaceListSection(id: cwd, threads: threadsByProject[cwd] ?? [])
        }
    }
}
