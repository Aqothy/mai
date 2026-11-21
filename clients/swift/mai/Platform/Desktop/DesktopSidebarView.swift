#if os(macOS)
    import SwiftUI

    struct DesktopSidebarView: View {
        @Bindable var store: ThreadStore

        @State private var filter = ThreadListFilter()
        @State private var isAgentRegistryPresented = false
        @State private var isSessionImportPresented = false

        @AppStorage(ThreadListDisplayMode.appStorageKey)
        private var displayModeRaw = ThreadListDisplayMode.recent.rawValue

        @AppStorage(CollapsedProjectDirectories.appStorageKey)
        private var collapsedProjects = CollapsedProjectDirectories()

        private var displayMode: ThreadListDisplayMode {
            ThreadListDisplayMode(rawValue: displayModeRaw) ?? .recent
        }

        private var selection: Binding<String?> {
            Binding(
                get: { store.selectedThreadID },
                set: { store.selectThread($0) }
            )
        }

        var body: some View {
            VStack(spacing: 0) {
                DesktopSidebarHeader(
                    store: store,
                    filter: $filter
                )
                Divider()

                DesktopSidebarList(
                    store: store,
                    filter: filter,
                    displayMode: displayMode,
                    selection: selection,
                    collapsedProjects: $collapsedProjects
                )

                Divider()
                DesktopSidebarFooter(
                    isAgentRegistryPresented: $isAgentRegistryPresented,
                    isSessionImportPresented: $isSessionImportPresented
                )
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
    }

    private struct DesktopSidebarHeader: View {
        let store: ThreadStore
        @Binding var filter: ThreadListFilter

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
                        filter: $filter
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
                        store.selectThread(nil)
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New Chat (⌘N)")
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
        let filter: ThreadListFilter
        let displayMode: ThreadListDisplayMode
        @Binding var selection: String?
        @Binding var collapsedProjects: CollapsedProjectDirectories

        @State private var topAligner = DesktopSidebarTopAligner()

        var body: some View {
            let threads = filter.apply(to: store)
            List(selection: $selection) {
                switch displayMode {
                case .recent:
                    ForEach(threads, id: \.id) { thread in
                        DesktopThreadRow(
                            thread: thread,
                            isUnread: store.isThreadUnread(thread.id),
                            isCompact: false,
                            providerName: store.providerDisplayName(for: thread),
                            markRead: { store.markThreadRead(thread.id) },
                            markUnread: { store.markThreadUnread(thread.id) },
                            rename: { try await store.renameThread(threadID: thread.id, title: $0) }
                        )
                        .tag(thread.id)
                    }
                case .byProject:
                    let groups = WorkspaceListGroups(threads: threads)
                    ForEach(groups.ungrouped, id: \.id) { thread in
                        DesktopThreadRow(
                            thread: thread,
                            isUnread: store.isThreadUnread(thread.id),
                            isCompact: true,
                            providerName: store.providerDisplayName(for: thread),
                            markRead: { store.markThreadRead(thread.id) },
                            markUnread: { store.markThreadUnread(thread.id) },
                            rename: { try await store.renameThread(threadID: thread.id, title: $0) }
                        )
                        .tag(thread.id)
                    }
                    ForEach(groups.projects) { section in
                        Section(isExpanded: expansionBinding(for: section.id)) {
                            ForEach(section.threads, id: \.id) { thread in
                                DesktopThreadRow(
                                    thread: thread,
                                    isUnread: store.isThreadUnread(thread.id),
                                    isCompact: true,
                                    providerName: store.providerDisplayName(for: thread),
                                    markRead: { store.markThreadRead(thread.id) },
                                    markUnread: { store.markThreadUnread(thread.id) },
                                    rename: { try await store.renameThread(threadID: thread.id, title: $0) }
                                )
                                .tag(thread.id)
                            }
                        } header: {
                            Text(section.name)
                        }
                    }
                }
            }
            .background {
                MacListTableViewIntrospector { tableView in
                    topAligner.attach(to: tableView)
                }
            }
            .task {
                topAligner.requestTopAlignment()
            }
            .onChange(of: threads.first?.id) { oldID, newID in
                guard oldID == nil || selection == newID else { return }
                topAligner.requestTopAlignment()
            }
            .listStyle(.sidebar)
            .contentMargins(
                .bottom,
                SidebarMetrics.listBottomMargin,
                for: .scrollContent
            )
            .padding(.top, SidebarMetrics.listTopInset)
            .overlay {
                if filter.isActive, threads.isEmpty, !store.threads.isEmpty {
                    DesktopSidebarFilteredEmptyState(query: filter.trimmedQuery)
                }
            }
            .modifier(ThreadListStatusModifier(store: store))
        }

        private func expansionBinding(for projectDirectory: String) -> Binding<Bool> {
            Binding(
                get: { collapsedProjects.isExpanded(projectDirectory) },
                set: { collapsedProjects.setExpanded($0, for: projectDirectory) }
            )
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

    private struct DesktopThreadRow: View {
        let thread: ThreadSummary
        let isUnread: Bool
        let isCompact: Bool
        let providerName: String?
        let markRead: () -> Void
        let markUnread: () -> Void
        let rename: (String) async throws -> Void

        @State private var isRenaming = false

        var body: some View {
            VStack(spacing: 0) {
                if isCompact {
                    CompactThreadRow(thread: thread, isUnread: isUnread)
                } else {
                    ThreadRow(thread: thread, isUnread: isUnread, providerName: providerName)
                }
            }
            .threadRenameAlert(isPresented: $isRenaming, currentTitle: thread.title, rename: rename)
            .contextMenu {
                Button("Rename…", systemImage: "pencil") { isRenaming = true }
                if isUnread {
                    Button("Mark as Read", systemImage: "envelope.open", action: markRead)
                } else {
                    Button("Mark as Unread", systemImage: "envelope.badge", action: markUnread)
                }
            }
        }
    }

    #if DEBUG
        #Preview("Desktop Sidebar") {
            NavigationSplitView {
                DesktopSidebarView(store: PreviewData.threadStore())
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
            } detail: {
                Color.clear
            }
        }

        #Preview("Desktop Sidebar Empty") {
            NavigationSplitView {
                DesktopSidebarView(store: ThreadStore(previewThreads: []))
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
            } detail: {
                Color.clear
            }
        }

        #Preview("Desktop Sidebar Loading") {
            NavigationSplitView {
                DesktopSidebarView(store: ThreadStore())
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
            } detail: {
                Color.clear
            }
        }
    #endif
#endif
