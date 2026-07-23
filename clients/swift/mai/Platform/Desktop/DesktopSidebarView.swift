import SwiftUI

struct DesktopSidebarView: View {
    let store: ThreadStore

    var body: some View {
        List(selection: selection) {
            ForEach(store.threads, id: \.id) { thread in
                ThreadRow(thread: thread)
                    .tag(thread.id)
            }
        }
        .listStyle(.sidebar)
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

    private var selection: Binding<String?> {
        Binding(
            get: { store.selectedThreadID },
            set: { selectedThreadID in
                store.selectThread(selectedThreadID)
            }
        )
    }
}

#if DEBUG
#Preview("Desktop Sidebar") {
    NavigationStack {
        DesktopSidebarView(store: PreviewData.threadStore())
    }
}
#endif
