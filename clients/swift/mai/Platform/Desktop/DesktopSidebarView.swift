import SwiftUI

struct DesktopSidebarView: View {
    let store: ThreadStore

    var body: some View {
        List(selection: selection) {
            Button("New Chat", systemImage: "square.and.pencil") {
                store.startNewDraft()
            }

            ForEach(store.threads, id: \.id) { thread in
                ThreadRow(
                    thread: thread,
                    isUnread: store.isThreadUnread(thread.id),
                    providerName: store.providerDisplayName(for: thread)
                )
                    .tag(thread.id)
                    .contextMenu {
                        if store.isThreadUnread(thread.id) {
                            Button("Mark as Read", systemImage: "envelope.open") {
                                store.markThreadRead(thread.id)
                            }
                        } else {
                            Button("Mark as Unread", systemImage: "envelope.badge") {
                                store.markThreadUnread(thread.id)
                            }
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .modifier(ThreadListStatusModifier(store: store))
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
