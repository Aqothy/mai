#if os(iOS)
    import UIKit

    /// A range of the transcript's text as UIKit's text system sees it,
    /// start before end.
    final class TranscriptTextRange: UITextRange {
        let from: TranscriptTextPosition
        let to: TranscriptTextPosition

        init(from: TextPosition, to: TextPosition) {
            self.from = TranscriptTextPosition(from)
            self.to = TranscriptTextPosition(to)
        }

        override var start: UITextPosition { from }
        override var end: UITextPosition { to }
        override var isEmpty: Bool { from.position == to.position }
    }
#endif
