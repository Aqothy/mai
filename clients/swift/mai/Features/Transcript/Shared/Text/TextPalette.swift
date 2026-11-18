import CoreGraphics
import Foundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The transcript's colors for one appearance, resolved on the main actor
/// and drawn with on any thread (`CGColor` is immutable). A class: every
/// placed row and band job holds it, one retain instead of one per color.
nonisolated final class TextPalette: @unchecked Sendable {
    let primary: CGColor
    let secondary: CGColor
    let tertiary: CGColor
    let separator: CGColor
    let inlineCodeBackground: CGColor
    let codeBackground: CGColor
    let codeBorder: CGColor
    let bubble: CGColor
    let warning: CGColor
    let error: CGColor
    /// Selection highlight in a key window, and in one that is not.
    let selection: CGColor
    let inactiveSelection: CGColor
    let isDark: Bool

    init(
        primary: CGColor, secondary: CGColor, tertiary: CGColor, separator: CGColor, inlineCodeBackground: CGColor,
        codeBackground: CGColor, codeBorder: CGColor, bubble: CGColor, warning: CGColor, error: CGColor,
        selection: CGColor, inactiveSelection: CGColor, isDark: Bool
    ) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.separator = separator
        self.inlineCodeBackground = inlineCodeBackground
        self.codeBackground = codeBackground
        self.codeBorder = codeBorder
        self.bubble = bubble
        self.warning = warning
        self.error = error
        self.selection = selection
        self.inactiveSelection = inactiveSelection
        self.isDark = isDark
    }

    func color(_ color: TextColor) -> CGColor? {
        switch color {
        case .primary: primary
        case .secondary: secondary
        case .tertiary: tertiary
        case .clear: nil
        case .rgba(let red, let green, let blue, let alpha):
            CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
        }
    }
}

extension TextPalette {
    #if os(macOS)
        /// The chat's colors: label colors for text, the primary color at the
        /// code block's opacity for its fill, the accent at 15 % for bubbles.
        @MainActor static func resolve(for appearance: NSAppearance) -> TextPalette {
            var palette: TextPalette?
            appearance.performAsCurrentDrawingAppearance {
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                palette = TextPalette(
                    primary: NSColor.labelColor.cgColor,
                    secondary: NSColor.secondaryLabelColor.cgColor,
                    tertiary: NSColor.tertiaryLabelColor.cgColor,
                    separator: NSColor.separatorColor.cgColor,
                    inlineCodeBackground: NSColor.labelColor.withAlphaComponent(0.07).cgColor,
                    codeBackground: NSColor.labelColor.withAlphaComponent(isDark ? 0.11 : 0.055).cgColor,
                    codeBorder: NSColor.labelColor.withAlphaComponent(0.08).cgColor,
                    bubble: NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor,
                    warning: NSColor.systemOrange.withAlphaComponent(0.12).cgColor,
                    error: NSColor.systemRed.withAlphaComponent(0.12).cgColor,
                    selection: NSColor.selectedTextBackgroundColor.cgColor,
                    inactiveSelection: NSColor.unemphasizedSelectedTextBackgroundColor.cgColor,
                    isDark: isDark)
            }
            return palette ?? .fallback
        }
    #else
        @MainActor static func resolve(for traits: UITraitCollection) -> TextPalette {
            func cg(_ color: UIColor) -> CGColor { color.resolvedColor(with: traits).cgColor }
            let isDark = traits.userInterfaceStyle == .dark
            return TextPalette(
                primary: cg(.label), secondary: cg(.secondaryLabel), tertiary: cg(.tertiaryLabel),
                separator: cg(.separator), inlineCodeBackground: cg(UIColor.label.withAlphaComponent(0.07)),
                codeBackground: cg(UIColor.label.withAlphaComponent(isDark ? 0.11 : 0.055)),
                codeBorder: cg(UIColor.label.withAlphaComponent(0.08)),
                bubble: cg(UIColor.tintColor.withAlphaComponent(0.15)),
                warning: cg(UIColor.systemOrange.withAlphaComponent(0.12)),
                error: cg(UIColor.systemRed.withAlphaComponent(0.12)),
                selection: cg(UIColor.tintColor.withAlphaComponent(0.25)),
                inactiveSelection: cg(UIColor.systemGray.withAlphaComponent(0.25)), isDark: isDark)
        }
    #endif

    private static let fallback = TextPalette(
        primary: CGColor(gray: 0, alpha: 0.85), secondary: CGColor(gray: 0, alpha: 0.5),
        tertiary: CGColor(gray: 0, alpha: 0.26), separator: CGColor(gray: 0, alpha: 0.1),
        inlineCodeBackground: CGColor(gray: 0, alpha: 0.07), codeBackground: CGColor(gray: 0, alpha: 0.055),
        codeBorder: CGColor(gray: 0, alpha: 0.08), bubble: CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 0.15),
        warning: CGColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 0.12),
        error: CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 0.12),
        selection: CGColor(srgbRed: 0.7, green: 0.84, blue: 1, alpha: 1),
        inactiveSelection: CGColor(gray: 0.86, alpha: 1), isDark: false)
}
