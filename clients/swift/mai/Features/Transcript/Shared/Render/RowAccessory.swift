import CoreGraphics
import Foundation

/// A native control on a row: copy buttons on code blocks, tables and
/// finished replies, and a finished turn's fork menu (PLAN Q3). Rows give
/// them as values; each platform makes pooled buttons for them, which bring
/// hit testing, hover, keyboard focus and accessibility for free.
nonisolated struct RowAccessory: Hashable, Sendable {
    enum Action: Hashable, Sendable {
        /// Copies `text`; `label` names it for accessibility ("Copy code").
        case copy(text: String, label: String)
        /// The fork menu of finished turn `turnID`.
        case fork(turnID: String)
    }

    let action: Action
    /// Row coordinates.
    let frame: CGRect

    static let size: CGFloat = 24
}
