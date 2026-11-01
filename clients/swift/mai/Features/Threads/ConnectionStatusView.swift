import SwiftUI

struct ConnectionStatusView: View {
    let store: ThreadStore

    var body: some View {
        // Keep one pill mounted throughout retries. Only its contents change
        // between the countdown and the connection attempt.
        if store.connectionState != .connected {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                ReconnectCountdownView(nextReconnectAt: store.nextReconnectAt)
                if store.nextReconnectAt != nil {
                    Button("Retry", action: store.retry)
                }
            }
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassSurface(in: .capsule)
        }
    }
}
