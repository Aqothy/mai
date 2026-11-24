import CoreGraphics
import Foundation

nonisolated struct MarkdownList: Hashable, Sendable {
    struct Item: Hashable, Sendable {
        /// `nil` for a regular item, `false` for `[ ]`, `true` for `[x]`/`[X]`.
        var taskChecked: Bool?
        var blocks: [MarkdownBlock]
    }

    /// Nil for a bulleted list.
    var startIndex: Int?
    /// Each item's optional task state and blocks.
    var items: [Item]
}
