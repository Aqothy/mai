import SwiftUI

struct ConnectionStatusView: View {
    let store: ThreadStore

    var body: some View {
        if store.connectionState != .connected, !store.threads.isEmpty {
            HStack {
                if store.connectionState == .connecting || store.nextReconnectAt != nil {
                    ReconnectAttemptStatusView(store: store, showsIcon: true)
                } else if store.automaticReconnectsExhausted {
                    Label(
                        "All \(ThreadStore.maximumReconnectAttempts) automatic retries failed",
                        systemImage: "network.slash"
                    )
                    Spacer()
                    Button("Retry", action: store.retry)
                }
            }
            .font(.caption)
            .padding()
            .background(.bar)
        }
    }
}
