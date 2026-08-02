#if os(iOS)
import SwiftUI

struct IOSRegularAppContainer: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore

    @State private var route: IOSNavigationRoute?
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            IOSThreadListView(
                store: store,
                newChat: {
                    route = .newChat
                    preferredCompactColumn = .detail
                },
                selectThread: { threadID in
                    store.prepareThreadForSelection(threadID)
                    route = .thread(threadID)
                    preferredCompactColumn = .detail
                },
                openAgentRegistry: {
                    route = .agentRegistry
                    preferredCompactColumn = .detail
                }
            )
            .navigationSplitViewColumnWidth(280)
            #if DEBUG
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink {
                            MockChatView()
                        } label: {
                            Label("Mock Chat", systemImage: "ladybug")
                        }
                    }
                }
            #endif
        } detail: {
            if route == .agentRegistry {
                ACPRegistryView(store: store)
            } else if let route {
                IOSChatDestinationView(
                    route: route,
                    store: store,
                    draftStore: draftStore
                )
                .id(route)
            } else {
                ContentUnavailableView(
                    "Select a Chat",
                    systemImage: "bubble.left.and.bubble.right"
                )
            }
        }
        .onChange(of: route, initial: true) { _, route in
            if route == nil {
                store.startNewDraft()
            }
        }
        .onChange(of: preferredCompactColumn) { _, column in
            if column == .sidebar {
                route = nil
            }
        }
    }
}
#endif
