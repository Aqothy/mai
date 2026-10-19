import GhosttyTerminal
import SwiftUI

/// Detail view for one terminal thread: primarily the terminal view with
/// minimal chrome. The terminal view, status overlay, and toolbar stay
/// separate view structs so status changes do not reconstruct the terminal.
struct TerminalThreadView: View {
    let attachment: TerminalAttachment
    var title = "Terminal"
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let backgroundColor = MaidTerminalAppearance.background(for: colorScheme)

        ZStack {
            Rectangle()
                .fill(backgroundColor)
                .ignoresSafeArea()

            AttachedTerminalView(attachment: attachment, colorScheme: colorScheme)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .overlay(alignment: .bottom) {
            TerminalStatusView(hasEnded: attachment.hasEnded)
                .padding(.bottom)
        }
        .navigationTitle(title)
        .navigationSubtitleIfAvailable(attachment.programTitle == title ? "" : attachment.programTitle)
        .inlineNavigationBarTitle()
    }
}

/// The package's terminal view over one attachment. Its own struct so
/// lifecycle changes elsewhere never rebuild it; it re-renders only for the
/// color scheme and text size.
private struct AttachedTerminalView: View {
    let attachment: TerminalAttachment
    let colorScheme: ColorScheme
    @State private var settings = TerminalSettings.shared

    var body: some View {
        TerminalView(
            terminal: attachment.terminal,
            io: attachment,
            configuration: MaidTerminalAppearance.configuration(for: colorScheme, fontSize: settings.fontSize))
            .onChange(of: colorScheme, initial: true) { _, colorScheme in
                attachment.colorScheme = colorScheme
            }
    }
}

private extension TerminalAttachment {
    var hasEnded: Bool {
        if case .exited = phase { return true }
        return false
    }
}
