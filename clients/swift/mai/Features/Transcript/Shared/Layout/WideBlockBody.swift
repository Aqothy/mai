import CoreGraphics
import Foundation

/// The part of a code block or table wider than its row: the lines or the
/// grid, shown in a horizontal scroller (PLAN 3.9, Q7) while the block's
/// background, header and toolbar stay in the row.
nonisolated struct WideBlockBody: Sendable {
    /// The body alone, laid out from (0, 0): what the scroller draws.
    let content: RowContentLayout
    /// Where the body sits in the row (row coordinates).
    let frame: CGRect
    /// The width the scroller scrolls over.
    let contentWidth: CGFloat

    /// A split code block shows one scrollbar, under its last chunk, as one
    /// `<pre>` does.
    var showsScroller: Bool {
        if case .codeBody(let code) = content { return !code.position.joinsBelow }
        return true
    }
}
