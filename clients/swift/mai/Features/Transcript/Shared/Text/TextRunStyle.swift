import CoreGraphics
import Foundation

/// What a run of text looks like beyond its font. Runs are split wherever
/// this changes (each style is its own attribute value), so every Core Text
/// run maps to exactly one.
nonisolated struct TextRunStyle: Hashable, Sendable {
    var color: TextColor = .primary
    var isInlineCode = false
    var isStruck = false
    var isUnderlined = false
    var linkIndex: Int?
}
