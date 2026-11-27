import CoreGraphics
import Foundation

/// A place in the transcript's text: a row and a UTF-16 offset into the
/// text it draws (PLAN 5). Model coordinates, not views, so a position
/// survives virtualization, streaming and re-layout.
nonisolated struct TextPosition: Hashable, Sendable {
    let rowID: String
    let offset: Int
}
