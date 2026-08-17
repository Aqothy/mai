import SwiftUI

struct IOSThreadListView: View {
    let store: ThreadStore
    let terminalStore: TerminalStore
    let projectFolders: ProjectFolderStore
    let newChat: (String?) -> Void
    let newTerminal: (TerminalOpenRequest) -> Void
    let selectThread: (String) -> Void
    let selectTerminal: (String) -> Void
    let openAgentRegistry: () -> Void
    let openSessionImport: () -> Void

    @State private var filter = ThreadListFilter()
    @State private var isTerminalFolderSelectionPresented = false

    @AppStorage(ThreadListDisplayMode.appStorageKey)
    private var displayModeRaw = ThreadListDisplayMode.recent.rawValue

    @AppStorage(CollapsedProjectDirectories.appStorageKey)
    private var collapsedProjects = CollapsedProjectDirectories()

    private var displayMode: ThreadListDisplayMode {
        ThreadListDisplayMode(rawValue: displayModeRaw) ?? .recent
    }

    var body: some View {
        // Hoisted so the filter/merge runs once per body evaluation; the
        // overlay below reads it as well.
        let items = self.filteredItems
        List {
            switch displayMode {
            case .recent:
                workspaceRows(items: items, isCompact: false)
            case .byProject:
                let groups = WorkspaceListGroups(
                    items: items,
                    projectDirectories: projectFolders.folders
                )
                workspaceRows(items: groups.ungrouped, isCompact: true)
                ForEach(groups.projects) { section in
                    Section {
                        if collapsedProjects.isExpanded(section.id) {
                            if section.items.isEmpty {
                                Button("New Chat", systemImage: "square.and.pencil") {
                                    newChat(section.id)
                                }
                            } else {
                                workspaceRows(items: section.items, isCompact: true)
                            }
                        }
                    } header: {
                        IOSProjectSectionHeader(
                            name: section.name,
                            isExpanded: collapsedProjects.isExpanded(section.id),
                            isSaved: projectFolders.contains(section.id),
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
                                projectFolders.remove(section.id)
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
                    projectFolders: projectFolders,
                    filter: $filter
                )
            }
        }
        .modifier(
            IOSThreadListBottomToolbar(
                newChat: { newChat(nil) },
                newTerminal: { isTerminalFolderSelectionPresented = true }
            )
        )
        .overlay {
            if filter.isActive, items.isEmpty,
                !(store.threads.isEmpty && terminalStore.terminals.isEmpty)
            {
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
                    && terminalStore.terminals.isEmpty
                    && (displayMode != .byProject || projectFolders.folders.isEmpty)
            )
        )
        .sheet(isPresented: $isTerminalFolderSelectionPresented) {
            FolderSelectionSheet(
                store: store,
                projectFolders: projectFolders,
                title: "New Terminal",
                selectedFolder: nil,
                onSelectExisting: openNewTerminal(at:),
                onSelectBrowsed: { directory, parentDirectory in
                    if let parentDirectory {
                        projectFolders.rememberParentFolder(parentDirectory)
                    }
                    openNewTerminal(at: directory)
                }
            )
        }
    }

    private func workspaceRows(items: [WorkspaceListItem], isCompact: Bool) -> some View {
        IOSWorkspaceRows(
            store: store,
            items: items,
            isCompact: isCompact,
            selectThread: selectThread,
            selectTerminal: selectTerminal,
            openTerminalHere: openNewTerminal(at:)
        )
    }

    private func openNewTerminal(at directory: String) {
        newTerminal(
            .new(
                cwd: directory,
                title: URL(filePath: directory).lastPathComponent
            )
        )
    }

    private var filteredItems: [WorkspaceListItem] {
        WorkspaceListItem.merged(
            threads: filter.apply(
                to: store.threads,
                providerID: store.providerID(for:)
            ),
            terminals: filter.apply(toTerminals: terminalStore.terminals)
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
                terminalStore: TerminalStore(),
                projectFolders: ProjectFolderStore(defaults: nil),
                newChat: { _ in },
                newTerminal: { _ in },
                selectThread: { _ in },
                selectTerminal: { _ in },
                openAgentRegistry: {},
                openSessionImport: {}
            )
        }
    }

    #Preview("iOS Thread List Loading") {
        NavigationStack {
            IOSThreadListView(
                store: ThreadStore(),
                terminalStore: TerminalStore(),
                projectFolders: ProjectFolderStore(defaults: nil),
                newChat: { _ in },
                newTerminal: { _ in },
                selectThread: { _ in },
                selectTerminal: { _ in },
                openAgentRegistry: {},
                openSessionImport: {}
            )
        }
    }
#endif
