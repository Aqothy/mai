import SwiftUI

struct ConnectionStatusView: View {
    let store: ThreadStore

    var body: some View {
        // In-flight connect attempts show nothing here — the list's loading
        // skeleton already covers them. The pill appears only when there is
        // something to say: a scheduled retry counting down, or automatic
        // retries exhausted.
        if showsPill {
            HStack(spacing: 8) {
                if store.automaticReconnectsExhausted {
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(.secondary)
                    Text("Disconnected")
                    Button("Retry", action: store.retry)
                } else if let nextReconnectAt = store.nextReconnectAt {
                    ProgressView()
                        .controlSize(.small)
                    ReconnectCountdownView(nextReconnectAt: nextReconnectAt)
                }
            }
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .modifier(StatusCapsuleBackground())
        }
    }

    private var showsPill: Bool {
        store.automaticReconnectsExhausted
            || (store.connectionState == .disconnected && store.nextReconnectAt != nil)
    }
}
