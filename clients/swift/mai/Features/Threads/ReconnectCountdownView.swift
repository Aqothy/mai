import SwiftUI

/// Shows the next reconnect countdown, then the in-flight connection attempt.
struct ReconnectCountdownView: View {
    let nextReconnectAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // Reserve the widest countdown string so status updates never
            // resize or shift the surrounding pill.
            Text("Reconnecting in 88s")
                .hidden()
                .overlay(alignment: .leading) {
                    Text(statusText(at: context.date))
                }
        }
        .monospacedDigit()
    }

    private func statusText(at now: Date) -> String {
        guard let nextReconnectAt else { return "Connecting…" }
        let seconds = max(0, Int(nextReconnectAt.timeIntervalSince(now).rounded(.up)))
        return "Reconnecting in \(seconds)s"
    }
}
