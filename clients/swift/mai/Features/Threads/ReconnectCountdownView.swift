import SwiftUI

/// Counts down to the next scheduled reconnect attempt.
struct ReconnectCountdownView: View {
    let nextReconnectAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // Reserve the widest countdown string so per-second updates
            // never resize or shift the pill.
            Text("Reconnecting in 88s")
                .hidden()
                .overlay(alignment: .leading) {
                    Text("Reconnecting in \(seconds(at: context.date))s")
                }
        }
        .monospacedDigit()
    }

    private func seconds(at now: Date) -> Int {
        max(0, Int(nextReconnectAt.timeIntervalSince(now).rounded(.up)))
    }
}
