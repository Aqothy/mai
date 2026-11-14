import SwiftUI

/// A settled table whose cell measurement can be prepared before its row is
/// realized.
nonisolated struct ChatTableLayoutRequest: Sendable {
    let id: String
    let table: ChatMarkdownTable
}
