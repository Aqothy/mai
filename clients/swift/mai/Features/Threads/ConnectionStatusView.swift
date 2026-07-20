import SwiftUI

struct ConnectionStatusView: View {
    let store: ThreadStore

    var body: some View {
        if store.connectionState != .connected, !store.threads.isEmpty {
            HStack {
                if store.connectionState == .connecting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reconnecting…")
                } else {
                    Label("Disconnected", systemImage: "network.slash")
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
