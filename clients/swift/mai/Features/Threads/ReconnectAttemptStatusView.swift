import SwiftUI

struct ReconnectAttemptStatusView: View {
    let store: ThreadStore
    var showsIcon = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if showsIcon {
                Label(statusText(at: context.date), systemImage: "arrow.clockwise")
            } else {
                Text(statusText(at: context.date))
            }
        }
        .monospacedDigit()
    }

    private func statusText(at date: Date) -> String {
        if store.connectionState == .connecting {
            guard store.reconnectAttempt > 0 else { return "Connecting…" }
            return "Reconnect attempt \(store.reconnectAttempt) of \(ThreadStore.maximumReconnectAttempts)…"
        }

        guard let nextReconnectAt = store.nextReconnectAt else {
            return "Connecting…"
        }
        let seconds = max(0, Int(ceil(nextReconnectAt.timeIntervalSince(date))))
        let attempt = min(store.reconnectAttempt + 1, ThreadStore.maximumReconnectAttempts)
        return "Reconnect attempt \(attempt) of \(ThreadStore.maximumReconnectAttempts) in \(seconds)s"
    }
}
