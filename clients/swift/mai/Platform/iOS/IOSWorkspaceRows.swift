#if os(iOS)
import SwiftUI

/// Rows for the Threads list, each row receiving only the values it renders.
struct IOSWorkspaceRows: View {
    let store: ThreadStore
    let threads: [ThreadSummary]
    var isCompact = false
    let selectThread: (String) -> Void

    var body: some View {
        ForEach(threads, id: \.id) { thread in
            IOSThreadRowButton(
                thread: thread,
                isUnread: store.isThreadUnread(thread.id),
                isCompact: isCompact,
                providerName: store.providerDisplayName(for: thread),
                select: { selectThread(thread.id) },
                markRead: { store.markThreadRead(thread.id) },
                markUnread: { store.markThreadUnread(thread.id) },
                rename: { try await store.renameThread(threadID: thread.id, title: $0) }
            )
            // The two-line row's title line box carries more headroom than the
            // caption line's descender, so an optically even row needs a
            // slightly shorter top inset.
            .listRowInsets(
                isCompact
                    ? EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
                    : EdgeInsets(top: 9, leading: 16, bottom: 11, trailing: 16)
            )
        }
        .buttonStyle(.plain)
    }
}

/// One thread row's chrome, its own invalidation boundary with the context menu
/// attached; the enclosing list supplies the row insets.
private struct IOSThreadRowButton: View {
    let thread: ThreadSummary
    let isUnread: Bool
    let isCompact: Bool
    let providerName: String?
    let select: () -> Void
    let markRead: () -> Void
    let markUnread: () -> Void
    let rename: (String) async throws -> Void

    @State private var isRenaming = false

    var body: some View {
        Button(action: select) {
            if isCompact {
                CompactThreadRow(thread: thread, isUnread: isUnread)
            } else {
                ThreadRow(thread: thread, isUnread: isUnread, providerName: providerName)
            }
        }
        .threadRenameAlert(isPresented: $isRenaming, currentTitle: thread.title, rename: rename)
        .contextMenu {
            Button("Rename…", systemImage: "pencil") { isRenaming = true }
            if isUnread {
                Button("Mark as Read", systemImage: "envelope.open", action: markRead)
            } else {
                Button("Mark as Unread", systemImage: "envelope.badge", action: markUnread)
            }
        }
    }
}

#endif
