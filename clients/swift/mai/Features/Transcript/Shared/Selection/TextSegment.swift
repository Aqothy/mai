import CoreGraphics
import Foundation

/// One laid-out piece of a row's selectable text: the row's text is its
/// segments' strings in order, with `separator` after each but the last (a
/// table's cells: tabs between cells, newlines between rows).
nonisolated struct TextSegment: Sendable {
    let layout: TextLayout
    /// The layout's origin in row coordinates.
    let origin: CGPoint
    /// Where the segment's text starts in the row's text.
    let start: Int
    /// Hit testing in row coordinates: the segment owns points in this rect
    /// (a table cell's box), or every point when nil.
    let hitRect: CGRect?

    var end: Int { start + layout.string.utf16.count }
}
