#if os(iOS)
import SwiftUI

struct IOSThreadListView: View {
    let store: ThreadStore
    let terminalStore: TerminalStore
    let newChat: () -> Void
    let newTerminal: (TerminalOpenRequest) -> Void
    let selectThread: (String) -> Void
    let selectTerminal: (String) -> Void
    let openAgentRegistry: () -> Void
    let openSessionImport: () -> Void

    @State private var filter = ThreadListFilter()

    var body: some View {
        // Hoisted so the filter/merge runs once per body evaluation; the
        // overlay below reads it as well.
        let items = self.filteredItems
        List {
            IOSWorkspaceRows(
                store: store,
                items: items,
                selectThread: selectThread,
                selectTerminal: selectTerminal,
                openTerminalHere: { cwd in
                    newTerminal(
                        .new(
                            cwd: cwd,
                            title: URL(filePath: cwd).lastPathComponent
                        ))
                }
            )
        }
        .listStyle(.plain)
        .navigationTitle("Threads")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter.query, prompt: "Search Threads")
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
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
            ToolbarItem(placement: .topBarTrailing) {
                IOSThreadFilterMenu(store: store, filter: $filter)
            }
        }
        .modifier(
            IOSThreadListBottomToolbar(
                newChat: newChat,
                newTerminal: { newTerminal(.new(cwd: "", title: nil)) }
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
        .modifier(ThreadListStatusModifier(store: store))
    }

    private var filteredItems: [WorkspaceListItem] {
        WorkspaceListItem.merged(
            threads: filter.apply(
                to: store.threads,
                isUnread: store.isThreadUnread,
                driver: store.driver(for:)
            ),
            terminals: filter.apply(toTerminals: terminalStore.terminals)
        )
    }
}

#if DEBUG
#Preview("iOS Thread List") {
    NavigationStack {
        IOSThreadListView(
            store: PreviewData.threadStore(),
            terminalStore: TerminalStore(),
            newChat: {},
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
            newChat: {},
            newTerminal: { _ in },
            selectThread: { _ in },
            selectTerminal: { _ in },
            openAgentRegistry: {},
            openSessionImport: {}
        )
    }
}
#endif
#endif
