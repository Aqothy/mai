import SwiftUI

struct ReconnectOverlayView: View {
    let store: ThreadStore

    var body: some View {
        ContentUnavailableView {
            Label("Reconnecting to maiD", systemImage: "arrow.clockwise")
        } description: {
            ReconnectAttemptStatusView(store: store)
        }
    }
}
