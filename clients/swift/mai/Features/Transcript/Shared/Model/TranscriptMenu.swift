import CoreGraphics
import Foundation

/// A menu a row offers (a finished turn's fork menu), described once and
/// made into an `NSMenu` or `UIMenu` by each platform.
struct TranscriptMenu {
    struct Item {
        let title: String
        var systemImage: String?
        /// Nil for an item that only holds `children`.
        var action: (() -> Void)?
        var children: [Item] = []
    }

    let items: [Item]
}
