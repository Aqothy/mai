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
            case .terminal, .agentRegistry, .sessionImport:
                // Containers route these destinations before this view.
                EmptyView()
            }
        }
        // Thread-list routes normally publish their selection before
        // navigation so the bounded initial page is ready on arrival. The
        // task remains the fallback for restored routes and owns new-draft
        // selection after the destination appears.
        .task(id: route) {
            switch route {
            case .newChat:
                store.startNewDraft()
            case let .thread(threadID):
                guard store.selectedThreadID != threadID else { return }
                store.selectThread(threadID)
            case .terminal, .agentRegistry, .sessionImport:
                break
            }
        }
    }
}
#endif
