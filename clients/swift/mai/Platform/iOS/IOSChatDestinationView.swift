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
        // Publishing the selection during the initial update would build a
        // cached thread's entire timeline before the push transition's first
        // frame, freezing navigation. task(id:) runs after that frame
        // commits, so the push starts immediately showing the placeholder
        // and the transcript builds while it is on screen.
        .task(id: route) {
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
