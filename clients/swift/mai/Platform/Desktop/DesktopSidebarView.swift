#if os(macOS)
    import SwiftUI

    struct DesktopSidebarView: View {
        @Bindable var store: ThreadStore
        let terminalStore: TerminalStore
        @Binding var terminalRoute: TerminalOpenRequest?

        @State private var filter = ThreadListFilter()
        @State private var isAgentRegistryPresented = false
        @State private var isSessionImportPresented = false
        @State private var isDeleteErrorPresented = false
        @State private var deleteErrorMessage = ""

        @AppStorage(ThreadListDisplayMode.appStorageKey)
        private var displayModeRaw = ThreadListDisplayMode.recent.rawValue

        @AppStorage(CollapsedProjectDirectories.appStorageKey)
        private var collapsedProjects = CollapsedProjectDirectories()

        private var displayMode: ThreadListDisplayMode {
            ThreadListDisplayMode(rawValue: displayModeRaw) ?? .recent
        }

        /// Bridges the merged workspace selection to the two stores: chats route
        /// through ThreadStore, terminals through the terminal route.
        private var selection: Binding<WorkspaceItemID?> {
            Binding(
                get: {
                    if case .existing(let terminalID) = terminalRoute {
                        return .terminal(terminalID)
                    }
                    if let threadID = store.selectedThreadID {
                        return .agentThread(threadID)
                    }
                    return nil
                },
                set: { newValue in
                    switch newValue {
                    case .agentThread(let threadID):
                        terminalRoute = nil
                        store.selectThread(threadID)
                    case .terminal(let terminalID):
                        store.selectThread(nil)
                        terminalRoute = .existing(terminalID: terminalID)
                    case nil:
                        terminalRoute = nil
                        store.selectThread(nil)
                    }
                }
            )
        }

        var body: some View {
            VStack(spacing: 0) {
                DesktopSidebarHeader(
                    store: store,
                    filter: $filter,
                    terminalRoute: $terminalRoute
                )
                Divider()

                DesktopSidebarList(
                    store: store,
                    terminalStore: terminalStore,
                    filter: filter,
                    displayMode: displayMode,
                    selection: selection,
                    collapsedProjects: $collapsedProjects,
                    openTerminalHere: openTerminalHereAction,
                    deleteTerminal: deleteTerminal
                )

                Divider()
                DesktopSidebarFooter(
                    isAgentRegistryPresented: $isAgentRegistryPresented,
                    isSessionImportPresented: $isSessionImportPresented
                )
            }
            .alert("Couldn’t Delete Terminal", isPresented: $isDeleteErrorPresented) {
                Button("OK") {}
            } message: {
                Text(deleteErrorMessage)
            }
            .sheet(isPresented: $isAgentRegistryPresented) {
                NavigationStack {
                    ACPRegistryView(store: store)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    isAgentRegistryPresented = false
                                }
                            }
                        }
                }
                .frame(minWidth: 500, minHeight: 440)
            }
            .sheet(isPresented: $isSessionImportPresented) {
                NavigationStack {
                    SessionImportView(
                        store: store,
                        openThread: { threadID in
                            isSessionImportPresented = false
                            terminalRoute = nil
                            store.selectThread(threadID)
                        }
                    )
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                isSessionImportPresented = false
                            }
                        }
                    }
                }
                .frame(minWidth: 500, minHeight: 440)
            }
        }

        // MARK: - Actions

        private func openTerminalHereAction(for thread: ThreadListEntry) -> (() -> Void)? {
            guard let cwd = thread.cwd, !cwd.isEmpty else { return nil }
            return {
                store.selectThread(nil)
                terminalRoute = .new(
                    cwd: cwd,
                    title: URL(filePath: cwd).lastPathComponent
                )
            }
        }

        private func deleteTerminal(_ terminalID: String) {
            Task {
                do {
                    try await terminalStore.deleteTerminal(terminalID: terminalID)
                    if terminalRoute == .existing(terminalID: terminalID) {
                        terminalRoute = nil
                    }
                } catch {
                    deleteErrorMessage = error.localizedDescription
                    isDeleteErrorPresented = true
                }
            }
        }
    }

    private struct DesktopSidebarHeader: View {
        let store: ThreadStore
        @Binding var filter: ThreadListFilter
        @Binding var terminalRoute: TerminalOpenRequest?

        @FocusState private var isSearchFocused: Bool

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: SidebarMetrics.searchControlSpacing) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("Search", text: $filter.query)
                            .textFieldStyle(.plain)
                            .focused($isSearchFocused)

                        if !filter.query.isEmpty {
                            Button("Clear search", systemImage: "xmark.circle.fill") {
                                filter.query = ""
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, SidebarMetrics.searchHorizontalPadding)
                    .frame(height: SidebarMetrics.controlHeight)
                    .background(
                        .quinary,
                        in: .rect(cornerRadius: SidebarMetrics.controlCornerRadius)
                    )

                    ThreadFilterMenu(
                        store: store,
                        filter: $filter,
                        showsActivityFilter: false
                    )
                    .labelStyle(.iconOnly)
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .frame(
                        width: SidebarMetrics.controlHeight,
                        height: SidebarMetrics.controlHeight
                    )
                    .help("View and filter options")
                }

                HStack(spacing: SidebarMetrics.actionSpacing) {
                    Button("New Chat", systemImage: "square.and.pencil") {
                        terminalRoute = nil
                        store.startNewDraft()
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New Chat (⌘N)")
                    .buttonStyle(SidebarActionButtonStyle())

                    Button("New Terminal", systemImage: "terminal") {
                        store.selectThread(nil)
                        terminalRoute = .new(cwd: "", title: nil)
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("New Terminal (⇧⌘N)")
                    .buttonStyle(SidebarActionButtonStyle())

                    Spacer(minLength: 0)
                }
                .padding(.vertical, SidebarMetrics.actionVerticalPadding)
            }
            .padding(.leading, SidebarMetrics.barPadding)
            .padding(.trailing, SidebarMetrics.headerTrailingPadding)
            .padding(.top, SidebarMetrics.barVerticalPadding)
            .background(.bar)
            .background {
                Button("Search") {
                    isSearchFocused = true
                }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            }
        }
    }

    private struct DesktopSidebarList: View {
        let store: ThreadStore
        let terminalStore: TerminalStore
        let filter: ThreadListFilter
        let displayMode: ThreadListDisplayMode
        @Binding var selection: WorkspaceItemID?
        @Binding var collapsedProjects: CollapsedProjectDirectories
        let openTerminalHere: (ThreadListEntry) -> (() -> Void)?
        let deleteTerminal: (String) -> Void

        var body: some View {
            let items = filteredItems
            List(selection: $selection) {
                if isLoading {
                    ThreadListSkeletonRows()
                } else {
                    switch displayMode {
                    case .recent:
                        ForEach(items) { item in
                            DesktopSelectableWorkspaceRow(
                                store: store,
                                item: item,
                                isCompact: false,
                                openTerminalHere: openTerminalHere,
                                deleteTerminal: deleteTerminal
                            )
                        }
                    case .byProject:
                        let groups = WorkspaceListGroups(items: items)
                        ForEach(groups.ungrouped) { item in
                            DesktopSelectableWorkspaceRow(
                                store: store,
                                item: item,
                                isCompact: true,
                                openTerminalHere: openTerminalHere,
                                deleteTerminal: deleteTerminal
                            )
                        }
                        ForEach(groups.projects) { section in
                            Section(isExpanded: expansionBinding(for: section.id)) {
                                ForEach(section.items) { item in
                                    DesktopSelectableWorkspaceRow(
                                        store: store,
                                        item: item,
                                        isCompact: true,
                                        openTerminalHere: openTerminalHere,
                                        deleteTerminal: deleteTerminal
                                    )
                                }
                            } header: {
                                Text(section.name)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .contentMargins(
                .bottom,
                SidebarMetrics.listBottomMargin,
                for: .scrollContent
            )
            .padding(.top, SidebarMetrics.listTopInset)
            .overlay {
                if filter.isActive, items.isEmpty, hasUnfilteredItems {
                    DesktopSidebarFilteredEmptyState(query: filter.trimmedQuery)
                }
            }
            .modifier(
                ThreadListStatusModifier(
                    store: store,
                    contentIsEmpty: !hasUnfilteredItems
                )
            )
        }

        private var isLoading: Bool {
            !hasUnfilteredItems && store.connectionState != .connected
        }

        private var hasUnfilteredItems: Bool {
            !store.threads.isEmpty || !terminalStore.terminals.isEmpty
        }

        private var filteredItems: [WorkspaceListItem] {
            WorkspaceListItem.merged(
                threads: filter.apply(
                    to: store.threads,
                    isUnread: store.isThreadUnread,
                    providerID: store.providerID(for:)
                ),
                terminals: filter.apply(toTerminals: terminalStore.terminals)
            )
        }

        private func expansionBinding(for projectDirectory: String) -> Binding<Bool> {
            Binding(
                get: { collapsedProjects.isExpanded(projectDirectory) },
                set: { collapsedProjects.setExpanded($0, for: projectDirectory) }
            )
        }
    }

    private struct DesktopSelectableWorkspaceRow: View {
        let store: ThreadStore
        let item: WorkspaceListItem
        let isCompact: Bool
        let openTerminalHere: (ThreadListEntry) -> (() -> Void)?
        let deleteTerminal: (String) -> Void

        var body: some View {
            DesktopWorkspaceRow(
                store: store,
                item: item,
                isCompact: isCompact,
                openTerminalHere: openTerminalHere,
                deleteTerminal: deleteTerminal
            )
            .tag(item.id)
        }
    }

    private struct DesktopSidebarFilteredEmptyState: View {
        let query: String

        var body: some View {
            VStack {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("No Matching Threads")
                    .font(.callout.weight(.semibold))
                Text(
                    query.isEmpty
                        ? "Try adjusting your filters."
                        : "No results for “\(query)”."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal)
        }
    }

    private struct DesktopSidebarFooter: View {
        @Binding var isAgentRegistryPresented: Bool
        @Binding var isSessionImportPresented: Bool

        var body: some View {
            HStack {
                Menu {
                    Button("Agent Registry…", systemImage: "puzzlepiece.extension") {
                        isAgentRegistryPresented = true
                    }
                    Button("Import Session…", systemImage: "square.and.arrow.down") {
                        isSessionImportPresented = true
                    }
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .controlSize(.large)
                .foregroundStyle(.secondary)
                .help("Agents and import")

                Spacer()
            }
            .padding(.horizontal, SidebarMetrics.rowLeadingPadding)
            .frame(height: SidebarMetrics.footerHeight)
            .background(.bar)
        }
    }

    /// One set of control metrics for the sidebar's header and footer bars.
    private enum SidebarMetrics {
        static let barPadding: CGFloat = 12
        static let headerTrailingPadding: CGFloat = 4
        /// Aligns header/footer content with the list rows' text leading edge.
        static let rowLeadingPadding: CGFloat = 16
        static let barVerticalPadding: CGFloat = 8
        static let searchHorizontalPadding: CGFloat = 8
        static let searchControlSpacing: CGFloat = 2
        static let actionSpacing: CGFloat = 8
        static let actionHorizontalPadding: CGFloat = 4
        static let actionVerticalPadding: CGFloat = 6
        static let footerHeight: CGFloat = 44
        static let controlHeight: CGFloat = 30
        static let listTopInset: CGFloat = 8
        static let listBottomMargin: CGFloat = 6
        static let controlCornerRadius: CGFloat = 7
    }

    /// Compact leading-aligned sidebar actions with a lightweight pressed state.
    private struct SidebarActionButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .lineLimit(1)
                .padding(.horizontal, SidebarMetrics.actionHorizontalPadding)
                .frame(height: SidebarMetrics.controlHeight)
                .background(
                    .quinary.opacity(configuration.isPressed ? 1 : 0),
                    in: .rect(cornerRadius: SidebarMetrics.controlCornerRadius)
                )
                .contentShape(.rect(cornerRadius: SidebarMetrics.controlCornerRadius))
        }
    }

    /// A concrete row root keeps List identity independent of which workspace
    /// domain the item belongs to.
    private struct DesktopWorkspaceRow: View {
        let store: ThreadStore
        let item: WorkspaceListItem
        let isCompact: Bool
        let openTerminalHere: (ThreadListEntry) -> (() -> Void)?
        let deleteTerminal: (String) -> Void

        var body: some View {
            VStack(spacing: 0) {
                switch item {
                case .agentThread(let thread):
                    DesktopThreadRow(
                        thread: thread,
                        isUnread: store.isThreadUnread(thread.id),
                        isCompact: isCompact,
                        providerName: store.providerDisplayName(for: thread),
                        markRead: { store.markThreadRead(thread.id) },
                        markUnread: { store.markThreadUnread(thread.id) },
                        openTerminalHere: openTerminalHere(thread)
                    )
                case .terminal(let summary):
                    DesktopTerminalRow(
                        summary: summary,
                        isCompact: isCompact,
                        delete: { deleteTerminal(summary.terminalID) }
                    )
                }
            }
        }
    }

    private struct DesktopThreadRow: View {
        let thread: ThreadListEntry
        let isUnread: Bool
        let isCompact: Bool
        let providerName: String?
        let markRead: () -> Void
        let markUnread: () -> Void
        let openTerminalHere: (() -> Void)?

        var body: some View {
            VStack(spacing: 0) {
                if isCompact {
                    CompactThreadRow(thread: thread, isUnread: isUnread)
                } else {
                    ThreadRow(thread: thread, isUnread: isUnread, providerName: providerName)
                }
            }
            .contextMenu {
                if isUnread {
                    Button("Mark as Read", systemImage: "envelope.open", action: markRead)
                } else {
                    Button("Mark as Unread", systemImage: "envelope.badge", action: markUnread)
                }
                if let openTerminalHere {
                    Button("Open Terminal Here", systemImage: "terminal", action: openTerminalHere)
                }
            }
        }
    }

    private struct DesktopTerminalRow: View {
        let summary: TerminalSummary
        let isCompact: Bool
        let delete: () -> Void

        var body: some View {
            VStack(spacing: 0) {
                if isCompact {
                    CompactTerminalRow(summary: summary)
                } else {
                    TerminalThreadRow(summary: summary)
                }
            }
            .contextMenu {
                Button("Delete Terminal", systemImage: "trash", role: .destructive, action: delete)
            }
        }
    }

    #if DEBUG
        #Preview("Desktop Sidebar") {
            NavigationSplitView {
                DesktopSidebarView(
                    store: PreviewData.threadStore(),
                    terminalStore: TerminalStore(),
                    terminalRoute: .constant(nil)
                )
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
            } detail: {
                Color.clear
            }
        }

        #Preview("Desktop Sidebar Empty") {
            NavigationSplitView {
                DesktopSidebarView(
                    store: ThreadStore(previewThreads: []),
                    terminalStore: TerminalStore(),
                    terminalRoute: .constant(nil)
                )
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
            } detail: {
                Color.clear
            }
        }

        #Preview("Desktop Sidebar Loading") {
            NavigationSplitView {
                DesktopSidebarView(
                    store: ThreadStore(),
                    terminalStore: TerminalStore(),
                    terminalRoute: .constant(nil)
                )
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
            } detail: {
                Color.clear
            }
        }
    #endif
#endif
