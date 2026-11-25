import CoreText
import CoreGraphics
import Foundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Fonts and metrics for every row kind. Built on the main actor from the
/// platform's text styles (Dynamic Type on iOS), then used for layout on
/// any thread. `version` changes whenever the fonts do, so a layout made
/// with older fonts is stale.
nonisolated struct TextStyle: Sendable {
    enum FontRole: Int, CaseIterable, Sendable {
        case body, code, bullet, callout, caption, heading1, heading2, heading3, heading4, heading5, heading6
    }

    let version: Int
    /// Every role's regular, bold, italic and bold italic faces, by
    /// `role.rawValue * 4 + bold + 2 * italic`.
    private let fonts: [TranscriptFont]

    // Prose (the chat's existing metrics).
    let lineSpacing: CGFloat = 2
    let blockSpacing: CGFloat = 16
    let listIndent: CGFloat = 20
    let listItemSpacing: CGFloat = 8
    let quoteIndent: CGFloat = 14
    let quoteBarWidth: CGFloat = 3
    // Rows.
    let messageVerticalInset: CGFloat = 10
    let bubbleHorizontalPadding: CGFloat = 14
    let bubbleVerticalPadding: CGFloat = 10
    /// Shape radii, drawn by row layers (layer properties, no style there).
    static let bubbleCornerRadius: CGFloat = 18
    static let codeCornerRadius: CGFloat = 18
    static let noticeCornerRadius: CGFloat = 12
    // Code blocks.
    let codeLineSpacing: CGFloat = 4
    let codeHorizontalInset: CGFloat = 16
    let codeBottomInset: CGFloat = 16
    let codeHeaderTopInset: CGFloat = 14
    let codeHeaderBottomInset: CGFloat = 10
    // Tables.
    let tableMinimumColumnWidth: CGFloat = 96
    let tableMaximumColumnWidth: CGFloat = 280
    let tableColumnSpacing: CGFloat = 24
    let tableCellVerticalPadding: CGFloat = 12
    let tableToolbarHeight: CGFloat = 44

    func font(_ role: FontRole, bold: Bool = false, italic: Bool = false) -> TranscriptFont {
        fonts[role.rawValue * 4 + (bold ? 1 : 0) + (italic ? 2 : 0)]
    }

    func headingRole(level: Int) -> FontRole {
        [.heading1, .heading2, .heading3, .heading4, .heading5, .heading6][max(1, min(6, level)) - 1]
    }

    var codeHeaderHeight: CGFloat {
        codeHeaderTopInset + font(.callout).lineHeight + codeHeaderBottomInset
    }

    var codeLineHeight: CGFloat { font(.code).lineHeight + codeLineSpacing }

    /// One column of the monospaced code font: an ASCII line's exact width
    /// per character.
    let codeColumnWidth: CGFloat

    init(version: Int, baseFont: (FontRole) -> CTFont) {
        self.version = version
        var fonts: [TranscriptFont] = []
        for role in FontRole.allCases {
            let base = TranscriptFont(font: baseFont(role))
            for index in 0..<4 {
                fonts.append(base.with(bold: index & 1 != 0, italic: index & 2 != 0))
            }
        }
        self.fonts = fonts
        let code = fonts[FontRole.code.rawValue * 4].font
        var zero: UniChar = 0x30
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(code, &zero, &glyph, 1)
        codeColumnWidth = CGFloat(CTFontGetAdvancesForGlyphs(code, .horizontal, &glyph, nil, 1))
    }
}

extension TextStyle {
    @MainActor private static var cached: TextStyle?
    @MainActor private static var cachedFonts: [CTFont] = []

    /// The style for the current text size and weight; the same value (and
    /// version) until the user's fonts change. Fonts compare whole (Core
    /// Foundation equality): Bold Text changes their weight, not their size.
    @MainActor static func current() -> TextStyle {
        let base = platformFonts()
        let fonts = FontRole.allCases.map(base)
        if let cached, fonts == cachedFonts { return cached }
        let style = TextStyle(version: (cached?.version ?? 0) + 1, baseFont: base)
        cached = style
        cachedFonts = fonts
        return style
    }

    @MainActor private static func platformFonts() -> (FontRole) -> CTFont {
        #if os(macOS)
            typealias PlatformFont = NSFont
        #else
            typealias PlatformFont = UIFont
        #endif
        func preferred(_ style: PlatformFont.TextStyle) -> CTFont {
            PlatformFont.preferredFont(forTextStyle: style) as CTFont
        }
        let callout = PlatformFont.preferredFont(forTextStyle: .callout)
        // The chat's existing heading scale, compact at chat widths.
        let fonts: [FontRole: CTFont] = [
            .body: preferred(.body),
            .code: PlatformFont.monospacedSystemFont(ofSize: callout.pointSize, weight: .regular) as CTFont,
            .bullet: preferred(.headline),
            .callout: callout as CTFont,
            .caption: preferred(.caption1),
            .heading1: preferred(.title2),
            .heading2: preferred(.title3),
            .heading3: preferred(.headline),
            .heading4: preferred(.body),
            .heading5: preferred(.callout),
            .heading6: preferred(.subheadline),
        ]
        let body = preferred(.body)
        return { fonts[$0] ?? body }
    }
}
