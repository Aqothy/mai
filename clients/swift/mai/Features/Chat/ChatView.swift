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

                if thread.latestTurn?.turnState == .error {
                    FailedTurnView(store: store, thread: thread)
                        .id(thread.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No Messages Yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("The chat timeline is the next feature to implement.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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

private struct FailedTurnView: View {
    let store: ThreadStore
    let thread: Thread

    @State private var isRetrying = false
    @State private var retryError: String?

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t Start Chat", systemImage: "exclamationmark.triangle")
        } description: {
            VStack {
                Text(thread.latestTurn?.error ?? "The provider could not start the turn.")
                if let retryError {
                    Text(retryError)
                        .foregroundStyle(.red)
                }
            }
        } actions: {
            Button(isRetrying ? "Retrying…" : "Retry") {
                retry()
            }
            .disabled(isRetrying || store.connectionState != .connected)
        }
    }

    private func retry() {
        guard !isRetrying, store.connectionState == .connected else { return }
        isRetrying = true
        retryError = nil
        Task {
            defer { isRetrying = false }
            do {
                try await store.retryFailedTurn(threadID: thread.id)
            } catch {
                retryError = error.localizedDescription
            }
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
