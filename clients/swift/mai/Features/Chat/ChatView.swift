import SwiftUI

struct ChatView: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore

    var body: some View {
        if let errorMessage = store.selectedThreadLoadErrorMessage {
            ContentUnavailableView {
                Label("Unable to Load Thread", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry", action: store.retry)
            }
        } else if let thread = store.selectedThread {
            VStack(alignment: .leading) {
                Text(thread.title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .accessibilityHeading(.h1)

                ContentUnavailableView(
                    "No Messages Yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("The chat timeline is the next feature to implement.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
        } else if store.selectedThreadID != nil, store.selectedThread == nil {
            ProgressView("Loading Chat…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DraftPromptView(store: store, draftStore: draftStore)
        }
    }
}

#if DEBUG
#Preview("Selected Chat") {
    NavigationStack {
        ChatView(
            store: PreviewData.threadStore(),
            draftStore: ThreadDraftStore()
        )
    }
}

#Preview("Draft Chat") {
    ChatView(
        store: ThreadStore(previewThreads: PreviewData.threads),
        draftStore: ThreadDraftStore()
    )
}
#endif
