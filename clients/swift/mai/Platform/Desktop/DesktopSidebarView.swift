import SwiftUI

struct DesktopSidebarView: View {
    @Bindable var store: ThreadStore

    @State private var isAgentRegistryPresented = false

    var body: some View {
        List(selection: $store.sidebarSelection) {
            Button("New Chat", systemImage: "square.and.pencil") {
                store.startNewDraft()
            }

            Button("Agent Registry", systemImage: "puzzlepiece.extension") {
                isAgentRegistryPresented = true
            }

            ForEach(store.threads, id: \.id) { thread in
                DesktopThreadRow(
                    thread: thread,
                    isUnread: store.isThreadUnread(thread.id),
                    providerName: store.providerDisplayName(for: thread),
                    markRead: { store.markThreadRead(thread.id) },
                    markUnread: { store.markThreadUnread(thread.id) }
                )
                .tag(thread.id)
            }
        }
        .listStyle(.sidebar)
        .modifier(ThreadListStatusModifier(store: store))
        .sheet(isPresented: $isAgentRegistryPresented) {
            NavigationStack {
                ACPRegistryView(store: store)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                isAgentRegistryPresented = false
                            }
                        }
                    }
            }
            .frame(minWidth: 500, minHeight: 440)
        }
    }
}

private struct DesktopThreadRow: View {
    let thread: ThreadListEntry
    let isUnread: Bool
    let providerName: String?
    let markRead: () -> Void
    let markUnread: () -> Void

    var body: some View {
        ThreadRow(thread: thread, isUnread: isUnread, providerName: providerName)
            .contextMenu {
                if isUnread {
                    Button("Mark as Read", systemImage: "envelope.open", action: markRead)
                } else {
                    Button("Mark as Unread", systemImage: "envelope.badge", action: markUnread)
                }
            }
    }
}

#if DEBUG
#Preview("Desktop Sidebar") {
    NavigationStack {
        DesktopSidebarView(store: PreviewData.threadStore())
    }
}
#endif
