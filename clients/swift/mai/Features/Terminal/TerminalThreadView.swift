import SwiftUI

/// Detail view for one terminal thread: primarily the Ghostty surface with
/// minimal chrome. Surface, status overlay, and toolbar stay separate view
/// structs so status changes do not reconstruct the terminal host.
struct TerminalThreadView: View {
    let controller: TerminalSessionController
    var title = "Terminal"
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let backgroundColor = MaidTerminalAppearance.background(for: colorScheme)

        ZStack {
            Rectangle()
                .fill(backgroundColor)
                .ignoresSafeArea()

            TerminalSurfaceHost(
                controller: controller,
                backgroundColor: backgroundColor
            )
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .overlay(alignment: .bottom) {
            TerminalStatusView(hasEnded: controller.hasEnded)
                .padding(.bottom)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
    /// Development-only harness: renders the adapter against the fake echo
    /// backend so the Ghostty integration can be exercised without a daemon.
    private struct TerminalPreviewHarness: View {
        @State private var context = TerminalPreviewBackend.makeContext()

        var body: some View {
            NavigationStack {
                TerminalThreadView(controller: context.controller, title: "Preview Terminal")
            }
        }
    }

    #Preview("Terminal") {
        TerminalPreviewHarness()
    }
#endif
