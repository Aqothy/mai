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
            if store.connectionState == .connecting, store.threads.isEmpty {
                ProgressView("Connecting to maiD…")
            } else if store.connectionState == .disconnected, store.threads.isEmpty {
                ContentUnavailableView {
                    Label("maiD Unavailable", systemImage: "network.slash")
                } description: {
                    Text(store.errorMessage ?? "Could not connect to the server.")
                } actions: {
                    Button("Retry", action: store.retry)
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
            set: store.selectThread
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
