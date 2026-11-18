import CoreGraphics
import Foundation

/// A row laid out: its height (whole points, spacing included) and content.
nonisolated struct RowLayout: Sendable {
    let rowID: String
    let key: RowLayoutKey
    let height: CGFloat
    let content: RowContentLayout
}
