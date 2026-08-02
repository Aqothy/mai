#if os(iOS)
import SwiftUI

struct IOSChatDestinationView: View {
    let route: IOSNavigationRoute
    let store: ThreadStore
    let draftStore: ThreadDraftStore

    var body: some View {
        Group {
            switch route {
            case .newChat:
                ChatView(store: store, draftStore: draftStore)
            case let .thread(threadID):
                if store.selectedThreadID == threadID {
                    ChatView(store: store, draftStore: draftStore)
                } else {
                    ProgressView("Opening Chat…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .agentRegistry:
                // Containers route the agent registry before this view.
                EmptyView()
            }
        }
        .onChange(of: route, initial: true) { _, route in
            switch route {
            case .newChat:
                store.startNewDraft()
            case let .thread(threadID):
                guard store.selectedThreadID != threadID else { return }
                store.selectThread(threadID)
            case .agentRegistry:
                break
            }
        }
    }
}
#endif
