import CoreGraphics
import Foundation

/// A shape drawn with the text, from line and run metrics: behind the glyphs
/// (inline code, quote bars, rules) or over them (underline, strikethrough).
nonisolated struct TextDecoration: Sendable {
    enum Kind: Sendable {
        case inlineCodeBackground
        case quoteBar
        case rule
        case taskUnchecked
        case taskChecked
        case underline
        case strikethrough
    }

    let kind: Kind
    let rect: CGRect
    let color: TextColor

    var isBehindText: Bool {
        switch kind {
        case .inlineCodeBackground, .quoteBar, .rule, .taskUnchecked, .taskChecked: true
        case .underline, .strikethrough: false
        }
    }
}
