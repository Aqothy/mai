#if os(iOS)
import SwiftUI

struct IOSThreadRows: View {
    let store: ThreadStore
    let threads: [ThreadListEntry]
    let selectThread: (String) -> Void

    var body: some View {
        ForEach(threads, id: \.id) { thread in
            IOSThreadRowButton(
                thread: thread,
                isUnread: store.isThreadUnread(thread.id),
                providerName: store.providerDisplayName(for: thread),
                select: { selectThread(thread.id) },
                markRead: { store.markThreadRead(thread.id) },
                markUnread: { store.markThreadUnread(thread.id) }
            )
        }
        .buttonStyle(.plain)
    }
}

/// One row's chrome, kept unary (a single top-level Button) to preserve the
/// List fast path and give each row its own invalidation boundary.
private struct IOSThreadRowButton: View {
    let thread: ThreadListEntry
    let isUnread: Bool
    let providerName: String?
    let select: () -> Void
    let markRead: () -> Void
    let markUnread: () -> Void

    var body: some View {
        Button(action: select) {
            ThreadRow(thread: thread, isUnread: isUnread, providerName: providerName)
        }
        // The title's taller line box carries more headroom than the
        // caption line's descender, so an optically even row needs a
        // slightly shorter top inset.
        .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 11, trailing: 16))
        .contextMenu {
            if isUnread {
                Button("Mark as Read", systemImage: "envelope.open", action: markRead)
            } else {
                Button("Mark as Unread", systemImage: "envelope.badge", action: markUnread)
            }
        }
    }
}
#endif
