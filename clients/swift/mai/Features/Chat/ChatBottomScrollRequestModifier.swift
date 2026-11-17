import SwiftUI

/// Handles explicit jump-to-bottom requests. Automatic following is driven
/// by the transcript's own geometry, and its reports alone say whether the
/// end shows: an animated jump has not arrived when it starts.
struct ChatBottomScrollRequestModifier: ViewModifier {
    let scrollState: ChatScrollState
    /// Does nothing while the transcript has no rows to scroll to; its
    /// first rows then land on the end by themselves.
    let pinToBottom: (_ animated: Bool) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: scrollState.bottomScrollRequest) { _, request in
            pinToBottom(request.animated)
        }
    }
}
