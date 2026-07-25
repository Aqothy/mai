#if os(iOS)
import SwiftUI

struct IOSSidebarView: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore
    @Binding var isPresented: Bool

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                Button("New Chat", systemImage: "square.and.pencil") {
                    store.startNewDraft()
                    isPresented = false
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

                ForEach(store.threads, id: \.id) { thread in
                    Button {
                        store.selectThread(thread.id)
                        isPresented = false
                    } label: {
                        ThreadRow(thread: thread)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
        .overlay {
            if store.threads.isEmpty {
                if store.connectionState == .connected {
                    ContentUnavailableView(
                        "No Threads",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Your conversations will appear here.")
                    )
                } else if store.automaticReconnectsExhausted {
                    ContentUnavailableView {
                        Label("maiD Unavailable", systemImage: "network.slash")
                    } description: {
                        Text(store.errorMessage ?? "Could not connect to the server.")
                    } actions: {
                        Button("Retry", action: store.retry)
                    }
                } else {
                    ReconnectOverlayView(store: store)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ConnectionStatusView(store: store)
        }
    }
}

#if DEBUG
#Preview("iOS Sidebar") {
    @Previewable @State var isPresented = true

    NavigationStack {
        IOSSidebarView(
            store: PreviewData.threadStore(),
            draftStore: ThreadDraftStore(),
            isPresented: $isPresented
        )
    }
}
#endif
#endif
