#if os(iOS)
import SwiftUI

struct IOSThreadListView: View {
    let store: ThreadStore
    let newChat: (String?) -> Void
    let selectThread: (String) -> Void
    let openAgentRegistry: () -> Void
    let openSessionImport: () -> Void

    @State private var filter = ThreadListFilter()
    @State private var projectErrorMessage: String?

    @AppStorage(ThreadListDisplayMode.appStorageKey)
    private var displayModeRaw = ThreadListDisplayMode.recent.rawValue

    @AppStorage(CollapsedProjectDirectories.appStorageKey)
    private var collapsedProjects = CollapsedProjectDirectories()

    private var displayMode: ThreadListDisplayMode {
        ThreadListDisplayMode(rawValue: displayModeRaw) ?? .recent
    }

    var body: some View {
        // Hoisted so the filter runs once per body evaluation; the overlay
        // below reads it as well.
        let threads = filter.apply(to: store)
        List {
            switch displayMode {
            case .recent:
                workspaceRows(threads: threads, isCompact: false)
            case .byProject:
                let groups = WorkspaceListGroups(
                    threads: threads,
                    projectDirectories: store.projects
                )
                workspaceRows(threads: groups.ungrouped, isCompact: true)
                ForEach(groups.projects) { section in
                    Section {
                        if collapsedProjects.isExpanded(section.id) {
                            if section.threads.isEmpty {
                                Button("New Chat", systemImage: "square.and.pencil") {
                                    newChat(section.id)
                                }
                            } else {
                                workspaceRows(threads: section.threads, isCompact: true)
                            }
                        }
                    } header: {
                        IOSProjectSectionHeader(
                            name: section.name,
                            isExpanded: collapsedProjects.isExpanded(section.id),
                            isSaved: store.projects.contains(section.id),
                            toggle: {
                                withAnimation(.snappy(duration: 0.2)) {
                                    collapsedProjects.setExpanded(
                                        !collapsedProjects.isExpanded(section.id),
                                        for: section.id
                                    )
                                }
                            },
                            newChat: {
                                newChat(section.id)
                            },
                            remove: {
                                removeProject(section.id)
                            }
                        )
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Threads")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter.query, prompt: "Search Threads")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu("Settings", systemImage: "gear") {
                    Button(
                        "Agent Registry",
                        systemImage: "puzzlepiece.extension",
                        action: openAgentRegistry
                    )
                    Button(
                        "Import Session",
                        systemImage: "square.and.arrow.down",
                        action: openSessionImport
                    )
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ThreadFilterMenu(
                    store: store,
                    filter: $filter
                )
            }
        }
        .modifier(
            IOSThreadListBottomToolbar(
                newChat: { newChat(nil) }
            )
        )
        .overlay {
            if filter.isActive, threads.isEmpty, !store.threads.isEmpty {
                if filter.trimmedQuery.isEmpty {
                    ContentUnavailableView(
                        "No Matching Threads",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Try adjusting your filters.")
                    )
                } else {
                    ContentUnavailableView.search(text: filter.trimmedQuery)
                }
            }
        }
        .modifier(
            ThreadListStatusModifier(
                store: store,
                contentIsEmpty: store.threads.isEmpty
                    && (displayMode != .byProject || store.projects.isEmpty)
            )
        )
        .alert(
            "Couldn’t Remove Project",
            isPresented: Binding(
                get: { projectErrorMessage != nil },
                set: { if !$0 { projectErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(projectErrorMessage ?? "")
        }
    }

    private func removeProject(_ path: String) {
        Task {
            do {
                try await store.removeProject(path)
            } catch {
                projectErrorMessage = error.localizedDescription
            }
        }
    }

    private func workspaceRows(threads: [ThreadSummary], isCompact: Bool) -> some View {
        IOSWorkspaceRows(
            store: store,
            threads: threads,
            isCompact: isCompact,
            selectThread: selectThread
        )
    }
}

/// A tappable project header carrying the fold chevron.
private struct IOSProjectSectionHeader: View {
    let name: String
    let isExpanded: Bool
    let isSaved: Bool
    let toggle: () -> Void
    let newChat: () -> Void
    let remove: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack {
                Text(name)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("New Chat", systemImage: "square.and.pencil", action: newChat)
            if isSaved {
                Divider()
                Button(
                    "Remove Project Folder",
                    systemImage: "folder.badge.minus",
                    role: .destructive,
                    action: remove
                )
            }
        }
        .accessibilityLabel("\(name), \(isExpanded ? "expanded" : "collapsed")")
        .accessibilityHint("Double tap to \(isExpanded ? "collapse" : "expand")")
    }
}

#if DEBUG
    #Preview("iOS Thread List") {
        NavigationStack {
            IOSThreadListView(
                store: PreviewData.threadStore(),
                newChat: { _ in },
                selectThread: { _ in },
                openAgentRegistry: {},
                openSessionImport: {}
            )
        }
    }

    #Preview("iOS Thread List Loading") {
        NavigationStack {
            IOSThreadListView(
                store: ThreadStore(),
                newChat: { _ in },
                selectThread: { _ in },
                openAgentRegistry: {},
                openSessionImport: {}
            )
        }
    }
#endif

#endif
