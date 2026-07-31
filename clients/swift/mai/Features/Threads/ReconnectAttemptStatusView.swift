import SwiftUI

struct ReconnectAttemptStatusView: View {
    let store: ThreadStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // Size against the widest possible string so per-second countdown
            // updates and state changes never resize or shift the pill.
            Text("Reconnecting in 88s")
                .hidden()
                .overlay(alignment: .leading) {
                    Text(statusText(at: context.date))
                }
        }
        .monospacedDigit()
    }

    private func statusText(at date: Date) -> String {
        if store.connectionState == .connecting {
            return store.reconnectAttempt == 0 ? "Connecting…" : "Reconnecting…"
        }
        guard let nextReconnectAt = store.nextReconnectAt else {
            return "Connecting…"
        }
        let seconds = max(0, Int(ceil(nextReconnectAt.timeIntervalSince(date))))
        return "Reconnecting in \(seconds)s"
    }
}
