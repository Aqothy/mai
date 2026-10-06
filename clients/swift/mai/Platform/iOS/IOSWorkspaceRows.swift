#if os(iOS)
import SwiftUI

/// Rows for the unified Threads list: agent chats and terminals merged in
/// the presentation layer, each row receiving only the values it renders.
struct IOSWorkspaceRows: View {
    let store: ThreadStore
    let items: [WorkspaceListItem]
    var isCompact = false
    let selectThread: (String) -> Void
    let selectTerminal: (String) -> Void
    let openTerminalHere: (String) -> Void

    var body: some View {
        ForEach(items) { item in
            IOSWorkspaceRow(
                store: store,
                item: item,
                isCompact: isCompact,
                selectThread: selectThread,
                selectTerminal: selectTerminal,
                openTerminalHere: openTerminalHere
            )
        }
        .buttonStyle(.plain)
    }
}

/// A single-root container keeps the row unary regardless of which workspace
/// domain the item belongs to, so List can template row identities from the
/// ForEach without evaluating every row's body.
private struct IOSWorkspaceRow: View {
    let store: ThreadStore
    let item: WorkspaceListItem
    let isCompact: Bool
    let selectThread: (String) -> Void
    let selectTerminal: (String) -> Void
    let openTerminalHere: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch item {
            case .agentThread(let thread):
                IOSThreadRowButton(
                    thread: thread,
                    isUnread: store.isThreadUnread(thread.id),
                    isCompact: isCompact,
                    providerName: store.providerDisplayName(for: thread),
                    select: { selectThread(thread.id) },
                    markRead: { store.markThreadRead(thread.id) },
                    markUnread: { store.markThreadUnread(thread.id) },
                    openTerminalHere: openTerminalHereAction(for: thread)
                )
            case .terminal(let summary):
                IOSTerminalRowButton(
                    summary: summary,
                    isCompact: isCompact,
                    select: { selectTerminal(summary.terminalID) }
                )
            }
        }
        // The two-line row's title line box carries more headroom than the
        // caption line's descender, so an optically even row needs a
        // slightly shorter top inset.
        .listRowInsets(
            isCompact
                ? EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
                : EdgeInsets(top: 9, leading: 16, bottom: 11, trailing: 16)
        )
    }

    private func openTerminalHereAction(for thread: ThreadListEntry) -> (() -> Void)? {
        guard let cwd = thread.cwd, !cwd.isEmpty else { return nil }
        return { openTerminalHere(cwd) }
    }
}

/// One agent-thread row's chrome, its own invalidation boundary with the
/// context menu attached; the enclosing row supplies the List insets.
private struct IOSThreadRowButton: View {
    let thread: ThreadListEntry
    let isUnread: Bool
    let isCompact: Bool
    let providerName: String?
    let select: () -> Void
    let markRead: () -> Void
    let markUnread: () -> Void
    let openTerminalHere: (() -> Void)?

    var body: some View {
        Button(action: select) {
            if isCompact {
                CompactThreadRow(thread: thread, isUnread: isUnread)
            } else {
                ThreadRow(thread: thread, isUnread: isUnread, providerName: providerName)
            }
        }
        .contextMenu {
            if isUnread {
                Button("Mark as Read", systemImage: "envelope.open", action: markRead)
            } else {
                Button("Mark as Unread", systemImage: "envelope.badge", action: markUnread)
            }
            if let openTerminalHere {
                Button("Open Terminal Here", systemImage: "terminal", action: openTerminalHere)
            }
        }
    }
}

/// One terminal row, mirroring the agent-row structure.
private struct IOSTerminalRowButton: View {
    let summary: TerminalSummary
    let isCompact: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            if isCompact {
                CompactTerminalRow(summary: summary)
            } else {
                TerminalThreadRow(summary: summary)
            }
        }
    }
}

#endif
