import SwiftUI

/// Presents the terminal running an agent's own login program (ACP terminal
/// authentication) while the account model has one open. The daemon restarts
/// the agent once that program exits successfully, so dismissing refreshes
/// the account.
struct ProviderSignInTerminalPresenter: ViewModifier {
    @Bindable var model: ProviderAccountModel
    @Environment(TerminalStore.self) private var terminalStore

    func body(content: Content) -> some View {
        content.sheet(
            isPresented: $model.isSignInTerminalPresented,
            onDismiss: {
                terminalStore.closeActiveTerminal()
                Task { await model.refresh() }
            }
        ) {
            if let terminalID = model.signInTerminalID {
                ProviderSignInTerminalSheet(
                    terminalID: terminalID,
                    terminalStore: terminalStore,
                    done: { model.isSignInTerminalPresented = false }
                )
            }
        }
    }
}

private struct ProviderSignInTerminalSheet: View {
    let terminalID: String
    let terminalStore: TerminalStore
    let done: () -> Void

    var body: some View {
        NavigationStack {
            TerminalThreadScreen(store: terminalStore, request: .existing(terminalID: terminalID))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: done)
                    }
                }
        }
        #if os(macOS)
            .frame(minWidth: 640, minHeight: 420)
        #endif
    }
}
