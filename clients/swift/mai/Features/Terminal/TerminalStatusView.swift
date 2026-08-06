import SwiftUI

/// Unobtrusive terminal status overlay. Receives only the values it renders
/// so lifecycle changes do not rebuild the terminal surface.
struct TerminalStatusView: View {
    let hasEnded: Bool

    var body: some View {
        if hasEnded {
            Label("Process ended", systemImage: "stop.circle")
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: .capsule)
                .accessibilityLabel("Terminal process ended")
        }
    }
}
