import SwiftUI

struct ConnectionStatusView: View {
    let store: ThreadStore

    var body: some View {
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
                    ReconnectAttemptStatusView(store: store)
                }
            }
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .modifier(StatusCapsuleBackground())
        }
    }
}
