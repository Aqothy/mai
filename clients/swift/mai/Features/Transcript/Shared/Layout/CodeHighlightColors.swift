import CoreGraphics
import Foundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Syntax colors for a code block from the chat's highlighter (highlight.js
/// in JavaScriptCore, serialized on its own actor), as color runs over the
/// code's UTF-16 offsets. Nil when the highlighter has no result or its text
/// differs from the code (ranges would not line up).
nonisolated enum CodeHighlightColors {
    static func colors(code: String, language: String?, isDark: Bool) async -> CodeColors? {
        guard
            let highlighted = await ChatCodeHighlighter.shared.highlight(
                code: code, language: language, theme: isDark ? .dark : .light)
        else { return nil }
        #if os(macOS)
            guard let converted = try? NSAttributedString(highlighted, including: \.appKit) else { return nil }
        #else
            guard let converted = try? NSAttributedString(highlighted, including: \.uiKit) else { return nil }
        #endif
        guard converted.string == code else { return nil }
        var runs: [CodeColors.Run] = []
        converted.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: converted.length)
        ) { value, range, _ in
            #if os(macOS)
                guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { return }
                let components = (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
            #else
                guard let color = value as? UIColor else { return }
                var components: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
                guard color.getRed(&components.0, green: &components.1, blue: &components.2, alpha: &components.3)
                else { return }
            #endif
            runs.append(
                CodeColors.Run(
                    range: range.location..<(range.location + range.length),
                    color: .rgba(
                        red: Float(components.0), green: Float(components.1), blue: Float(components.2),
                        alpha: Float(components.3))))
        }
        return CodeColors(code: code, runs: runs, isDark: isDark)
    }
}
