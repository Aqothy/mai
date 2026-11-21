import CoreGraphics
import Foundation

/// A fenced code block: a header with its language, then one line per
/// source line, never wrapped. The height is analytic (header + lines ×
/// line height + inset), so it never changes when colors arrive; the width
/// is the longest line, scrolled horizontally when wider than the row.
nonisolated struct CodeLayout: Sendable {
    let label: TextLayout
    let body: TextLayout
    let code: String
    let headerHeight: CGFloat
    /// The language label's top inside the block.
    let labelTop: CGFloat
    /// The body's text origin inside the block.
    let bodyOrigin: CGPoint
    /// The block's size: at least the row's width; as tall as its lines.
    let size: CGSize
    /// The body's full width with insets, the extent a horizontal scroller
    /// scrolls over.
    let contentWidth: CGFloat
    /// The syntax colors drawn, kept so the same code laid out again (a new
    /// width or text size) keeps them; nil while plain.
    let colors: CodeColors?

    var isHighlighted: Bool { colors != nil }

    /// The theme its syntax colors are for (dark or not); nil while plain.
    var colorsAreDark: Bool? { colors?.isDark }

    var isWiderThanBlock: Bool { contentWidth > size.width + 0.5 }

    static func make(
        code: String, language: String?, colors: CodeColors?, width: CGFloat, style: TextStyle
    ) -> CodeLayout {
        let colors = colors?.code == code ? colors : nil
        let label = TextLayoutEngine.layout(
            AttributedTextBuilder.plain(displayName(language), role: .callout, color: .secondary, style: style),
            width: .greatestFiniteMagnitude, options: .init(lineSpacing: 0))
        var text = AttributedTextBuilder.plain("", role: .code, color: .primary, style: style)
        let font = style.font(.code)
        let utf16 = code.utf16
        var cursor = 0
        func appendPlain(upTo end: Int) {
            guard end > cursor else { return }
            text.append(Self.substring(code, utf16, cursor..<end), font: font, style: TextRunStyle())
            cursor = end
        }
        for run in colors?.runs ?? [] where run.range.lowerBound >= cursor && run.range.upperBound <= utf16.count {
            appendPlain(upTo: run.range.lowerBound)
            text.append(Self.substring(code, utf16, run.range), font: font, style: TextRunStyle(color: run.color))
            cursor = run.range.upperBound
        }
        appendPlain(upTo: utf16.count)
        let body = TextLayoutEngine.layout(
            text, width: .greatestFiniteMagnitude,
            options: .init(lineSpacing: 0, wraps: false, fixedLineHeight: style.codeLineHeight))
        let headerHeight = style.codeHeaderHeight
        let contentWidth = ceil(body.size.width + 2 * style.codeHorizontalInset)
        // Bytes, not Characters: "\r\n" is one Character.
        let lineCount = max(1, code.utf8.reduce(into: 1) { count, byte in if byte == 0x0A { count += 1 } })
        let height = headerHeight + CGFloat(lineCount) * style.codeLineHeight + style.codeBottomInset
        return CodeLayout(
            label: label, body: body, code: code, headerHeight: headerHeight, labelTop: style.codeHeaderTopInset,
            bodyOrigin: CGPoint(x: style.codeHorizontalInset, y: headerHeight),
            size: CGSize(width: width, height: ceil(height)), contentWidth: contentWidth, colors: colors)
    }

    /// The same block at another row width: code never wraps, so its text
    /// layout is the same and only the block's width changes.
    func resized(toWidth width: CGFloat) -> CodeLayout {
        CodeLayout(
            label: label, body: body, code: code, headerHeight: headerHeight, labelTop: labelTop,
            bodyOrigin: bodyOrigin, size: CGSize(width: width, height: size.height), contentWidth: contentWidth,
            colors: colors)
    }

    private static func substring(_ code: String, _ utf16: String.UTF16View, _ range: Range<Int>) -> String {
        let start = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let end = utf16.index(start, offsetBy: range.count)
        return String(code[start..<end])
    }

    /// The label a code block's language shows under.
    static func displayName(_ language: String?) -> String {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty else {
            return "Code"
        }
        let names: [String: String] = [
            "bash": "Bash", "sh": "Bash", "shell": "Bash", "csharp": "C#", "cs": "C#", "cpp": "C++", "c++": "C++",
            "css": "CSS", "go": "Go", "golang": "Go", "html": "HTML", "javascript": "JavaScript",
            "js": "JavaScript", "jsx": "JavaScript", "json": "JSON", "kotlin": "Kotlin", "markdown": "Markdown",
            "md": "Markdown", "objective-c": "Objective-C", "objc": "Objective-C", "python": "Python",
            "py": "Python", "ruby": "Ruby", "rb": "Ruby", "rust": "Rust", "sql": "SQL", "swift": "Swift",
            "typescript": "TypeScript", "ts": "TypeScript", "tsx": "TypeScript", "xml": "XML", "yaml": "YAML",
            "yml": "YAML",
        ]
        return names[language.lowercased()] ?? language.capitalized
    }
}
