import GhosttyTerminal
import SwiftUI

/// Embeds the package's Ghostty surface and passes only stable integration
/// objects. This view is a separate invalidation boundary from status chrome
/// and toolbars: repeated terminal output must never rebuild it.
struct TerminalSurfaceHost: View {
    let controller: TerminalSessionController
    let backgroundColor: Color
    #if !canImport(UIKit)
    @FocusState private var isTerminalFocused: Bool
    #endif

    var body: some View {
        #if canImport(UIKit)
        MaidTerminalSurfaceView(
            context: controller.viewState,
            inputSession: controller.session,
            backgroundColor: backgroundColor
        )
        #else
        TerminalSurfaceView(context: controller.viewState)
            .terminalFocusOnAppear($isTerminalFocused)
            .background(backgroundColor)
        #endif
    }
}
