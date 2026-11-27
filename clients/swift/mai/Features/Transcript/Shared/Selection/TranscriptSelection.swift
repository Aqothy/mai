import CoreGraphics
import Foundation

/// The reader's selection: where it started and where it ends now. The rows
/// between are wholly selected; `anchor` may come after `focus` (a drag
/// upwards).
nonisolated struct TranscriptSelection: Hashable, Sendable {
    var anchor: TextPosition
    var focus: TextPosition
    /// True when created by Select All (renders full column width instead of
    /// ragged-right per-line rects).
    var isSelectAll: Bool

    init(anchor: TextPosition, focus: TextPosition, isSelectAll: Bool = false) {
        self.anchor = anchor
        self.focus = focus
        self.isSelectAll = isSelectAll
    }

    init(caret: TextPosition) {
        self.init(anchor: caret, focus: caret, isSelectAll: false)
    }

    var isEmpty: Bool { anchor == focus }
}
