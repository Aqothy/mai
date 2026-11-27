import CoreGraphics
import Foundation

/// The reader's selection: where it started and where it ends now. The rows
/// between are wholly selected; `anchor` may come after `focus` (a drag
/// upwards).
nonisolated struct TranscriptSelection: Hashable, Sendable {
    var anchor: TextPosition
    var focus: TextPosition

    init(anchor: TextPosition, focus: TextPosition) {
        self.anchor = anchor
        self.focus = focus
    }

    init(caret: TextPosition) {
        self.init(anchor: caret, focus: caret)
    }

    var isEmpty: Bool { anchor == focus }
}
