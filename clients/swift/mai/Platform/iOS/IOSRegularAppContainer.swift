#if os(iOS)
import SwiftUI

struct IOSRegularAppContainer: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore
    let terminalStore: TerminalStore

    @State private var route: IOSNavigationRoute?
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            IOSThreadListView(
                store: store,
                terminalStore: terminalStore,
                newChat: {
                    route = .newChat
                    preferredCompactColumn = .detail
                },
                newTerminal: { request in
                    route = .terminal(request)
                    preferredCompactColumn = .detail
                },
                selectThread: { threadID in
                    store.selectThread(threadID)
                    route = .thread(threadID)
                    preferredCompactColumn = .detail
                },
                selectTerminal: { terminalID in
                    route = .terminal(.existing(terminalID: terminalID))
                    preferredCompactColumn = .detail
                },
                openAgentRegistry: {
                    route = .agentRegistry
                    preferredCompactColumn = .detail
                },
                openSessionImport: {
                    route = .sessionImport
                    preferredCompactColumn = .detail
                }
            )
            .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 400)
        } detail: {
            if route == .agentRegistry {
                ACPRegistryView(store: store)
            } else if route == .sessionImport {
                SessionImportView(
                    store: store,
                    openThread: { threadID in
                        store.selectThread(threadID)
                        route = .thread(threadID)
                    }
                )
            } else if case let .terminal(request) = route {
                TerminalThreadScreen(
                    store: terminalStore,
                    request: request,
                    onCreated: { terminalID in
                        route = .terminal(.existing(terminalID: terminalID))
                    }
                )
            } else if let route {
                IOSChatDestinationView(
                    route: route,
                    store: store,
                    draftStore: draftStore
                )
                .id(route)
            } else {
                ContentUnavailableView {
                    Label("No Thread Selected", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Choose a thread from the sidebar, or start a new chat.")
                } actions: {
                    Button("New Chat", systemImage: "square.and.pencil") {
                        route = .newChat
                        preferredCompactColumn = .detail
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .onChange(of: route, initial: true) { _, route in
            if case .terminal = route {
                return
            }
            terminalStore.closeActiveTerminal()
        }
        .onChange(of: preferredCompactColumn) { _, column in
            if column == .sidebar {
                terminalStore.closeActiveTerminal()
            }
        }
    }
}
#endif
