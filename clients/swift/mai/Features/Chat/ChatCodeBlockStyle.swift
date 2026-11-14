import Foundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Typography for fenced code in native text views. Matches the SwiftUI
/// presentation of a streaming block (`.callout.monospaced()` with 4 pt line
/// spacing), so a block keeps its metrics when it settles.
nonisolated enum ChatCodeBlockStyle {
    static let horizontalInset: CGFloat = 16
    static let bottomInset: CGFloat = 16
    static let lineSpacing: CGFloat = 4

    static var font: ChatPlatformFont {
        .monospacedSystemFont(
            ofSize: ChatPlatformFont.preferredFont(forTextStyle: .callout).pointSize,
            weight: .regular
        )
    }

    static func attributedString(code: String) -> NSMutableAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        #if os(macOS)
            let color = NSColor.labelColor
        #else
            let color = UIColor.label
        #endif
        return NSMutableAttributedString(
            string: code,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    /// Overlays syntax colors on `code`'s plain attributed form. The
    /// highlighter only contributes foreground colors, so line metrics
    /// (and therefore the prepared row height) are unchanged. A
    /// highlighter result whose text differs from the source is ignored
    /// rather than risking mismatched ranges.
    static func highlightedAttributedString(
        block: ChatMarkdownCodeBlock,
        theme: ChatCodeHighlightTheme
    ) async -> NSMutableAttributedString {
        let base = attributedString(code: block.code)
        guard
            let highlighted = await ChatCodeHighlighter.shared.highlight(
                code: block.code,
                language: block.language,
                theme: theme
            )
        else { return base }
        #if os(macOS)
            let converted = try? NSAttributedString(highlighted, including: \.appKit)
        #else
            let converted = try? NSAttributedString(highlighted, including: \.uiKit)
        #endif
        guard let colored = converted, colored.string == base.string else { return base }

        colored.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: colored.length)
        ) { value, range, _ in
            guard let color = value as? ChatPlatformColor else { return }
            base.addAttribute(.foregroundColor, value: color, range: range)
        }
        return base
    }
}
