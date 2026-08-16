import SwiftUI

struct ConnectionStatusView: View {
    let store: ThreadStore

    var body: some View {
        // Keep one pill mounted throughout retries. Only its contents change
        // between the countdown, connection attempt, and manual retry states.
        if store.connectionState != .connected {
            HStack(spacing: 8) {
                if store.automaticReconnectsExhausted {
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(.secondary)
                    Text("Disconnected")
                    Button("Retry", action: store.retry)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    ReconnectCountdownView(nextReconnectAt: store.nextReconnectAt)
                }
            }
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassSurface(in: .capsule)
        }
    }
}
