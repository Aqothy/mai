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

    /// iOS shows a navigation subtitle from iOS 26; macOS always has.
    @ViewBuilder
    func navigationSubtitleIfAvailable(_ subtitle: String) -> some View {
        #if os(iOS)
            if #available(iOS 26.0, *) {
                self.navigationSubtitle(subtitle)
            } else {
                self
            }
        #else
            self.navigationSubtitle(subtitle)
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
