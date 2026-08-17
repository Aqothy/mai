import SwiftUI

struct IOSAppContainer: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore
    let projectFolders: ProjectFolderStore
    let terminalStore: TerminalStore

    @State private var path: [IOSNavigationRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            IOSThreadListView(
                store: store,
                terminalStore: terminalStore,
                projectFolders: projectFolders,
                newChat: { workingDirectory in
                    path.append(.newChat(workingDirectory: workingDirectory))
                },
                newTerminal: { request in
                    path.append(.terminal(request))
                },
                selectThread: { threadID in
                    store.selectThread(threadID)
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
                            store.selectThread(threadID)
                            path = [.thread(threadID)]
                        }
                    )
                } else if case .terminal(let request) = route {
                    TerminalThreadScreen(store: terminalStore, request: request)
                } else {
                    IOSChatDestinationView(
                        route: route,
                        store: store,
                        draftStore: draftStore,
                        projectFolders: projectFolders
                    )
                }
            }
            .toolbar {
                if ChatPerformanceLab.isEnabled {
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink {
                            MockChatView()
                        } label: {
                            Label("Mock Chat", systemImage: "ladybug")
                        }
                    }
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

#if DEBUG
    #Preview("iOS App") {
        IOSAppContainer(
            store: PreviewData.threadStore(),
            draftStore: ThreadDraftStore(),
            projectFolders: ProjectFolderStore(defaults: nil),
            terminalStore: TerminalStore()
        )
    }
#endif
