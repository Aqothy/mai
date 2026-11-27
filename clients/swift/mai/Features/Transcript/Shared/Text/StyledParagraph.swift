import CoreGraphics
import Foundation

/// A block-level paragraph of a `StyledText`: where it starts and how its
/// lines sit. Hard line breaks inside it continue at `headIndent` with
/// line spacing only.
nonisolated struct StyledParagraph: Sendable {
    struct TaskMarker: Sendable {
        var x: CGFloat
        var checked: Bool
    }

    /// UTF-16 offset of its first character.
    var start: Int
    var firstLineIndent: CGFloat
    var headIndent: CGFloat
    /// Space above it, after the line spacing of the line before.
    var spacingBefore: CGFloat
    /// The x of each quote bar beside it.
    var quoteBars: [CGFloat]
    /// A thematic break: a full-width line over clear text.
    var isRule = false
    /// Optional GFM task-list checkbox drawn in the leading list gutter.
    var taskMarker: TaskMarker?
}
