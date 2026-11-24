import CoreGraphics
import Foundation

nonisolated struct MarkdownList: Hashable, Sendable {
    struct Item: Hashable, Sendable {
        /// `nil` for a regular item, `false` for `[ ]`, `true` for `[x]`/`[X]`.
        var taskChecked: Bool?
        var blocks: [MarkdownBlock]

        init(taskChecked: Bool? = nil, blocks: [MarkdownBlock]) {
            self.taskChecked = taskChecked
            self.blocks = blocks
        }
    }

    /// Nil for a bulleted list.
    var startIndex: Int?
    /// Each item's optional task state and blocks.
    var items: [Item]
}
