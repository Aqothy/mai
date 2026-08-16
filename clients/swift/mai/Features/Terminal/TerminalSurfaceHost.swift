import GhosttyTerminal
import SwiftUI

/// Embeds the package's Ghostty surface and passes only stable integration
/// objects. This view is a separate invalidation boundary from status chrome
/// and toolbars: repeated terminal output must never rebuild it.
struct TerminalSurfaceHost: View {
    let controller: TerminalSessionController
    let backgroundColor: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TerminalSurfaceView(context: controller.viewState)
            .background(backgroundColor)
            .onChange(of: colorScheme) { _, newScheme in
                controller.viewState.adopt(colorScheme: newScheme)
            }
            .onAppear {
                controller.viewState.adopt(colorScheme: colorScheme)
            }
    }
}
