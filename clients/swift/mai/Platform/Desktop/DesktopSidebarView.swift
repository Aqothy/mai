import SwiftUI

struct DesktopSidebarView: View {
    @Bindable var store: ThreadStore
    let terminalStore: TerminalStore
    @Binding var terminalRoute: TerminalOpenRequest?

    @State private var isAgentRegistryPresented = false
    @State private var isSessionImportPresented = false
    @State private var isDeleteErrorPresented = false
    @State private var deleteErrorMessage = ""

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
        List(selection: selection) {
            Menu {
                Button("New Chat", systemImage: "square.and.pencil") {
                    terminalRoute = nil
                    store.startNewDraft()
                }
                Button("New Terminal", systemImage: "terminal") {
                    store.selectThread(nil)
                    terminalRoute = .new(cwd: "", title: nil)
                }
            } label: {
                Label("New Thread", systemImage: "square.and.pencil")
            }

            Button("Agent Registry", systemImage: "puzzlepiece.extension") {
                isAgentRegistryPresented = true
            }

            Button("Import Session", systemImage: "square.and.arrow.down") {
                isSessionImportPresented = true
            }

            ForEach(WorkspaceListItem.merged(threads: store.threads, terminals: terminalStore.terminals)) { item in
                DesktopWorkspaceRow(
                    store: store,
                    item: item,
                    openTerminalHere: openTerminalHereAction,
                    deleteTerminal: deleteTerminal
                )
                .tag(item.id)
            }
        }
        .listStyle(.sidebar)
        .modifier(ThreadListStatusModifier(store: store))
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

/// A concrete row root keeps List identity independent of which workspace
/// domain the item belongs to.
private struct DesktopWorkspaceRow: View {
    let store: ThreadStore
    let item: WorkspaceListItem
    let openTerminalHere: (ThreadListEntry) -> (() -> Void)?
    let deleteTerminal: (String) -> Void

    var body: some View {
        switch item {
        case .agentThread(let thread):
            DesktopThreadRow(
                thread: thread,
                isUnread: store.isThreadUnread(thread.id),
                providerName: store.providerDisplayName(for: thread),
                markRead: { store.markThreadRead(thread.id) },
                markUnread: { store.markThreadUnread(thread.id) },
                openTerminalHere: openTerminalHere(thread)
            )
        case .terminal(let summary):
            DesktopTerminalRow(
                summary: summary,
                delete: { deleteTerminal(summary.terminalID) }
            )
        }
    }
}

private struct DesktopThreadRow: View {
    let thread: ThreadListEntry
    let isUnread: Bool
    let providerName: String?
    let markRead: () -> Void
    let markUnread: () -> Void
    let openTerminalHere: (() -> Void)?

    var body: some View {
        ThreadRow(thread: thread, isUnread: isUnread, providerName: providerName)
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
    let delete: () -> Void

    var body: some View {
        TerminalThreadRow(summary: summary)
            .contextMenu {
                Button("Delete Terminal", systemImage: "trash", role: .destructive, action: delete)
            }
    }
}

#if DEBUG
#Preview("Desktop Sidebar") {
    NavigationStack {
        DesktopSidebarView(
            store: PreviewData.threadStore(),
            terminalStore: TerminalStore(),
            terminalRoute: .constant(nil)
        )
    }
}
#endif
