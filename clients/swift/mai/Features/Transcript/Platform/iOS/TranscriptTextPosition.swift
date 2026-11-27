#if os(iOS)
    import UIKit

    /// A `TextPosition` as UIKit's text system sees it.
    final class TranscriptTextPosition: UITextPosition {
        let position: TextPosition

        init(_ position: TextPosition) {
            self.position = position
        }
    }
#endif
