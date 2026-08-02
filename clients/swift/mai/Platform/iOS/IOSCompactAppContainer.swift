#if os(iOS)
import SwiftUI

struct IOSCompactAppContainer: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore

    @State private var path: [IOSNavigationRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            IOSThreadListView(
                store: store,
                newChat: {
                    path.append(.newChat)
                },
                selectThread: { threadID in
                    store.prepareThreadForSelection(threadID)
                    path.append(.thread(threadID))
                },
                openAgentRegistry: {
                    path.append(.agentRegistry)
                }
            )
            .navigationDestination(for: IOSNavigationRoute.self) { route in
                if route == .agentRegistry {
                    ACPRegistryView(store: store)
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
            if path.isEmpty {
                store.startNewDraft()
            }
        }
    }
}
#endif
