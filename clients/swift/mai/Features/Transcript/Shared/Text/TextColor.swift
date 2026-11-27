import CoreGraphics
import Foundation

/// A glyph or decoration color by role, resolved by `TextPalette` when
/// drawing. Layouts therefore stay valid across light and dark appearance;
/// only syntax colors, which come per theme, are concrete.
nonisolated enum TextColor: Hashable, Sendable {
    case primary
    case secondary
    case tertiary
    /// Text kept for selection and copy but not drawn (a thematic break's
    /// source spelling).
    case clear
    /// sRGB components, 0...1.
    case rgba(red: Float, green: Float, blue: Float, alpha: Float)
}
