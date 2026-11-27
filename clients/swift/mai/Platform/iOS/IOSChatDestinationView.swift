#if os(iOS)
import SwiftUI

struct IOSChatDestinationView: View {
    let route: IOSNavigationRoute
    let store: ThreadStore
    let draftStore: ThreadDraftStore
    let openThread: (String) -> Void
    let openDraft: () -> Void

    var body: some View {
        Group {
            switch route {
            case .newChat(let workingDirectory):
                ChatView(
                    store: store,
                    draftStore: draftStore,
                    initialWorkingDirectory: workingDirectory,
                    openThread: openThread,
                    openDraft: openDraft
                )
            case .thread(let threadID):
                if store.selectedThreadID == threadID {
                    ChatView(
                        store: store,
                        draftStore: draftStore,
                        openThread: openThread,
                        openDraft: openDraft
                    )
                } else {
                    ProgressView("Opening Chat…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .agentRegistry, .sessionImport:
                // Containers route these destinations before this view.
                EmptyView()
            }
        }
    }
}

#endif
