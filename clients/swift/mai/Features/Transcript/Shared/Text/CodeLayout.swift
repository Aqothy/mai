import CoreGraphics
import Foundation

/// A fenced code block: a header with its language, then one unified virtual
/// `TextLayout` body (`wraps: false`, `FontWidthTable` widths, 4-column tab
/// stops). Every line's width is exact and only visible lines and columns draw.
nonisolated struct CodeLayout: Sendable {
    let label: TextLayout
    let body: TextLayout
    let code: String
    let headerHeight: CGFloat
    let labelTop: CGFloat
    let bodyOrigin: CGPoint
    let size: CGSize
    let contentWidth: CGFloat
    let colors: CodeColors?
    let styleVersion: Int

    var bodySize: CGSize { body.size }
    var utf16Length: Int { body.length }
    var retainedBytes: Int { body.retainedBytes + label.retainedBytes }
    var isHighlighted: Bool { colors != nil }
    var colorsAreDark: Bool? { colors?.isDark }
    var isWiderThanBlock: Bool { contentWidth > size.width + 0.5 }

    static func make(
        code: String, language: String?, colors: CodeColors?, width: CGFloat, style: TextStyle,
        previous: CodeLayout? = nil
    ) -> CodeLayout {
        let colors = colors?.code == code ? colors : nil
        let display = displayName(language)
        let label =
            previous.flatMap { $0.label.string == display && $0.styleVersion == style.version ? $0.label : nil }
            ?? TextLayoutEngine.layout(
                AttributedTextBuilder.plain(display, role: .callout, color: .secondary, style: style),
                width: .greatestFiniteMagnitude, options: .init(lineSpacing: 0))
        let prepared = PreparedText(code: code, colors: colors, style: style)
        let body = prepared.fit(width: .greatestFiniteMagnitude)
        let headerHeight = style.codeHeaderHeight
        let contentWidth = ceil(body.size.width + 2 * style.codeHorizontalInset)
        let height = Self.height(lines: max(1, body.lines.count), style: style)
        return CodeLayout(
            label: label, body: body, code: code, headerHeight: headerHeight, labelTop: style.codeHeaderTopInset,
            bodyOrigin: CGPoint(x: style.codeHorizontalInset, y: headerHeight),
            size: CGSize(width: width, height: height), contentWidth: contentWidth, colors: colors,
            styleVersion: style.version)
    }

    /// Analytic height (independent of width and syntax colors).
    static func height(for code: String, style: TextStyle) -> CGFloat {
        let lineCount = max(1, code.utf8.reduce(into: 1) { count, byte in if byte == 0x0A { count += 1 } })
        return height(lines: lineCount, style: style)
    }

    /// O(1) analytic height from precomputed line count.
    static func height(lines: Int, style: TextStyle) -> CGFloat {
        ceil(style.codeHeaderHeight + CGFloat(max(1, lines)) * style.codeLineHeight + style.codeBottomInset)
    }

    /// Code never wraps, so resize keeps the body and only updates the card width.
    func resized(toWidth width: CGFloat) -> CodeLayout {
        CodeLayout(
            label: label, body: body, code: code, headerHeight: headerHeight, labelTop: labelTop,
            bodyOrigin: bodyOrigin, size: CGSize(width: width, height: size.height), contentWidth: contentWidth,
            colors: colors, styleVersion: styleVersion)
    }

    func drawBody(at origin: CGPoint, clip: CGRect, palette: TextPalette, in context: CGContext) {
        TextRenderer.draw(body, at: origin, clip: clip, palette: palette, in: context)
    }

    func offset(closestTo local: CGPoint) -> Int {
        body.offset(closestTo: local)
    }

    func selectionRects(for range: Range<Int>) -> [CGRect] {
        body.selectionRects(for: range)
    }

    func caretRect(for utf16Offset: Int) -> CGRect? {
        body.caretRect(for: utf16Offset)
    }

    /// O(log lines) `memcmp` unchanged height for streaming code blocks
    /// (keeps 25k-line code stream updates at ~0.02 ms on the main thread).
    func unchangedBodyHeight(comparedTo other: CodeLayout) -> CGFloat {
        guard styleVersion == other.styleVersion, colors == other.colors else { return 0 }
        if code.isEmpty && other.code.isEmpty { return .infinity }
        guard let aLines = body.prepared.codeLines, let bLines = other.body.prepared.codeLines,
            let lineH = body.prepared.options.fixedLineHeight,
            lineH == other.body.prepared.options.fixedLineHeight
        else { return 0 }

        guard let diffByte = RowContentDiff.firstDifferingByte(code, other.code) else { return .infinity }
        let starts = other.code.utf8.count >= code.utf8.count ? bLines : aLines
        guard !starts.isEmpty else { return 0 }
        var low = 0
        var high = starts.count
        while low + 1 < high {
            let mid = (low + high) / 2
            if starts[mid].byteRange.lowerBound <= diffByte { low = mid } else { high = mid }
        }
        return CGFloat(min(low, min(aLines.count, bLines.count))) * lineH
    }

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
