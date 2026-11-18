#if os(iOS)
    import UIKit

    /// One line's piece of a selection, for UIKit's highlight and handles.
    final class TranscriptSelectionRect: UITextSelectionRect {
        private let frame: CGRect
        private let isStart: Bool
        private let isEnd: Bool

        init(_ frame: CGRect, isStart: Bool, isEnd: Bool) {
            self.frame = frame
            self.isStart = isStart
            self.isEnd = isEnd
        }

        override var rect: CGRect { frame }
        override var writingDirection: NSWritingDirection { .natural }
        override var containsStart: Bool { isStart }
        override var containsEnd: Bool { isEnd }
        override var isVertical: Bool { false }
    }
#endif
