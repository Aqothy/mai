#if os(iOS)
import SwiftUI

struct IOSAppContainer: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore

    @State private var path: [IOSNavigationRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            IOSThreadListView(
                store: store,
                newChat: { workingDirectory in
                    path.append(.newChat(workingDirectory: workingDirectory))
                },
                selectThread: { threadID in
                    store.selectThread(threadID)
                    path.append(.thread(threadID))
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
                } else {
                    IOSChatDestinationView(
                        route: route,
                        store: store,
                        draftStore: draftStore,
                        openThread: { threadID in
                            store.selectThread(threadID)
                            path.append(.thread(threadID))
                        },
                        openDraft: {
                            path.append(.newChat(workingDirectory: nil))
                        }
                    )
                }
            }
        }
        // NavigationStack's path is the sole owner of iOS thread selection.
        // Driving selection from the path instead of destination onDisappear
        // avoids a delayed pop completion clearing a freshly re-pushed thread.
        .onChange(of: path, initial: true) { _, newPath in
            let target = IOSNavigationRoute.selectedThreadID(in: newPath)
            if store.selectedThreadID != target {
                store.selectThread(target)
            }
        }
        #if DEBUG
            .modifier(
                ChatRealThreadBenchmarkRunner(
                    store: store,
                    selectThread: { threadID in
                        store.selectThread(threadID)
                        path = [.thread(threadID)]
                    }
                )
            )
        #endif
    }
}

#if DEBUG
    #Preview("iOS App") {
        IOSAppContainer(
            store: PreviewData.threadStore(),
            draftStore: ThreadDraftStore()
        )
    }
#endif

#endif
