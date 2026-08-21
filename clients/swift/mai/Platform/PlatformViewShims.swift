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

    /// Give SwiftUI-rendered chat prose the native text-selection pointer.
    /// Rich text rendered by `NSTextView` supplies the same cursor itself.
    @ViewBuilder
    func chatTextPointerStyle() -> some View {
        #if os(macOS)
            if #available(macOS 26.0, *) {
                self.pointerStyle(.horizontalText)
            } else {
                self
            }
        #else
            self
        #endif
    }
}
