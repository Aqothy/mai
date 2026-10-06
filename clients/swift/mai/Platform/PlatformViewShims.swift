import SwiftUI

extension View {
    /// iOS pins compact inline navigation titles; macOS has no navigation-bar
    /// display mode, so the call disappears there.
    @ViewBuilder
    func inlineNavigationBarTitle() -> some View {
        #if os(iOS)
            self.navigationBarTitleDisplayMode(.inline)
        #else
            self
        #endif
    }

    /// Interactive keyboard dismissal only exists where a software keyboard
    /// does.
    @ViewBuilder
    func dismissesKeyboardInteractively() -> some View {
        #if os(iOS)
            self.scrollDismissesKeyboard(.interactively)
        #else
            self
        #endif
    }
}
