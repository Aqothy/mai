import SwiftUI

/// Handles explicit jump-to-bottom requests. Automatic following is driven
/// by the transcript's own geometry.
struct ChatBottomScrollRequestModifier: ViewModifier {
    let scrollState: ChatScrollState
    /// Returns false while the transcript has no rows to scroll to; its
    /// first rows then land on the end by themselves.
    let pinToBottom: (_ animated: Bool) -> Bool

    func body(content: Content) -> some View {
        content.onChange(of: scrollState.bottomScrollRequest) { _, request in
            if pinToBottom(request.animated) {
                scrollState.noteEndVisibility(true)
            }
        }
    }
}
