import CoreGraphics
import Foundation

nonisolated struct MarkdownList: Hashable, Sendable {
    /// Nil for a bulleted list.
    var startIndex: Int?
    /// Each item's blocks.
    var items: [[MarkdownBlock]]
}
