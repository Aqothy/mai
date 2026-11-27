import CoreGraphics
import Foundation

/// What a row's layout depends on. A layout whose key differs from the row's
/// current one is stale: shown until its replacement lands, never trusted
/// for height.
nonisolated struct RowLayoutKey: Hashable, Sendable {
    let contentVersion: Int
    /// The column width the row was laid out at.
    let width: CGFloat
    let styleVersion: Int
}
