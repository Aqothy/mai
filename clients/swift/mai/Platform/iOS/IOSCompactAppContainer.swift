#if os(iOS)
import SwiftUI

struct IOSCompactAppContainer: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore
    let terminalStore: TerminalStore

    @State private var path: [IOSNavigationRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            IOSThreadListView(
                store: store,
                terminalStore: terminalStore,
                newChat: {
                    path.append(.newChat)
                },
                newTerminal: { request in
                    path.append(.terminal(request))
                },
                selectThread: { threadID in
                    store.prepareThreadForSelection(threadID)
                    path.append(.thread(threadID))
                },
                selectTerminal: { terminalID in
                    path.append(.terminal(.existing(terminalID: terminalID)))
                },
                openAgentRegistry: {
                    path.append(.agentRegistry)
                },
                openSessionImport: {
                    path.append(.sessionImport)
                }
            )
            .navigationDestination(for: IOSNavigationRoute.self) { route in
                if route == .agentRegistry {
                    ACPRegistryView(store: store)
                } else if route == .sessionImport {
                    SessionImportView(
                        store: store,
                        openThread: { threadID in
                            store.prepareThreadForSelection(threadID)
                            path = [.thread(threadID)]
                        }
                    )
                } else if case let .terminal(request) = route {
                    TerminalThreadScreen(store: terminalStore, request: request)
                } else {
                    IOSChatDestinationView(
                        route: route,
                        store: store,
                        draftStore: draftStore
                    )
                }
            }
        }
        .onChange(of: path, initial: true) { _, path in
            // Detach is navigation-driven: when the visible top of the stack
            // stops being a terminal, release control; the shell keeps
            // running on the daemon.
            if case .terminal = path.last {
                return
            }
            terminalStore.closeActiveTerminal()
        }
    }
}
#endif
