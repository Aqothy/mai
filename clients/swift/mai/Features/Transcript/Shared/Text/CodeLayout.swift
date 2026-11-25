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
    /// Where this chunk sits inside a split oversized code block (`.single` for
    /// normal code blocks).
    let position: TranscriptBlockPosition

    var isHighlighted: Bool { colors != nil }

    /// The theme its syntax colors are for (dark or not); nil while plain.
    var colorsAreDark: Bool? { colors?.isDark }

    var isWiderThanBlock: Bool { contentWidth > size.width + 0.5 }

    static func make(
        code: String, language: String?, colors: CodeColors?, width: CGFloat, style: TextStyle,
        position: TranscriptBlockPosition = .single, previous: CodeLayout? = nil
    ) -> CodeLayout {
        let colors = colors?.code == code ? colors : nil
        let hasHeader = !position.joinsAbove
        let display = hasHeader ? displayName(language) : ""
        let label: TextLayout
        if hasHeader {
            label =
                previous.flatMap { !$0.position.joinsAbove && $0.label.string == display ? $0.label : nil }
                ?? TextLayoutEngine.layout(
                    AttributedTextBuilder.plain(display, role: .callout, color: .secondary, style: style),
                    width: .greatestFiniteMagnitude, options: .init(lineSpacing: 0))
        } else {
            label = .empty
        }
        let bodyOptions = TextLayoutEngine.Options(lineSpacing: 0, wraps: false, fixedLineHeight: style.codeLineHeight)
        var incremental: TextLayout?
        if colors == nil, let previous, previous.colors == nil, !previous.code.isEmpty,
            code.hasPrefix(previous.code), previous.body.lines.count >= 3, !previous.body.hasComplexBiDi
        {
            // Streaming plain fence: keep all finished lines before the last
            // line of `previous.code` and build/typeset ONLY the growing suffix.
            let keepCount = previous.body.lines.count - 1
            let resumeUTF16 = previous.body.lines[keepCount].range.lowerBound
            let utf16 = code.utf16
            if resumeUTF16 > 0, resumeUTF16 < utf16.count {
                let startIdx = utf16.index(utf16.startIndex, offsetBy: resumeUTF16)
                let suffixText = buildStyledCode(String(code[startIdx...]), colors: nil, style: style)
                incremental = TextLayoutEngine.layoutSuffix(
                    fullString: code, suffix: suffixText, width: .greatestFiniteMagnitude,
                    options: bodyOptions, appendingTo: previous.body, keepCount: keepCount)
            }
        }
        let body =
            incremental
            ?? TextLayoutEngine.layout(
                buildStyledCode(code, colors: colors, style: style), width: .greatestFiniteMagnitude,
                options: bodyOptions)
        let headerHeight = hasHeader ? style.codeHeaderHeight : 0
        // A chunk of a split block scrolls over the whole block's width.
        let contentWidth = ceil(
            max(body.size.width, CGFloat(position.widestLineColumns) * style.codeColumnWidth)
                + 2 * style.codeHorizontalInset)
        let height = Self.height(for: code, style: style, position: position)
        return CodeLayout(
            label: label, body: body, code: code, headerHeight: headerHeight, labelTop: style.codeHeaderTopInset,
            bodyOrigin: CGPoint(x: style.codeHorizontalInset, y: headerHeight),
            size: CGSize(width: width, height: height), contentWidth: contentWidth, colors: colors,
            position: position)
    }

    /// Analytic height (independent of width and syntax colors).
    static func height(
        for code: String, style: TextStyle, position: TranscriptBlockPosition = .single
    ) -> CGFloat {
        let lineCount = max(1, code.utf8.reduce(into: 1) { count, byte in if byte == 0x0A { count += 1 } })
        let header = position.joinsAbove ? 0 : style.codeHeaderHeight
        let bottom = position.joinsBelow ? 0 : style.codeBottomInset
        return ceil(header + CGFloat(lineCount) * style.codeLineHeight + bottom)
    }

    /// The same block at another row width: code never wraps, so its text
    /// layout is the same and only the block's width changes.
    func resized(toWidth width: CGFloat) -> CodeLayout {
        CodeLayout(
            label: label, body: body, code: code, headerHeight: headerHeight, labelTop: labelTop,
            bodyOrigin: bodyOrigin, size: CGSize(width: width, height: size.height), contentWidth: contentWidth,
            colors: colors, position: position)
    }

    private static func buildStyledCode(_ code: String, colors: CodeColors?, style: TextStyle) -> StyledText {
        var text = StyledText()
        text.paragraphs = [StyledParagraph(start: 0, firstLineIndent: 0, headIndent: 0, spacingBefore: 0, quoteBars: [])]
        let font = style.font(.code)
        if let runs = colors?.runs, !runs.isEmpty {
            let utf16 = code.utf16
            let total = utf16.count
            var cursorOffset = 0
            var cursorIndex = utf16.startIndex
            func appendSlice(upTo target: Int, style runStyle: TextRunStyle) {
                guard target > cursorOffset else { return }
                let end = utf16.index(cursorIndex, offsetBy: target - cursorOffset)
                text.append(String(code[cursorIndex..<end]), font: font, style: runStyle)
                cursorOffset = target
                cursorIndex = end
            }
            for run in runs where run.range.lowerBound >= cursorOffset && run.range.upperBound <= total {
                appendSlice(upTo: run.range.lowerBound, style: TextRunStyle())
                appendSlice(upTo: run.range.upperBound, style: TextRunStyle(color: run.color))
            }
            appendSlice(upTo: total, style: TextRunStyle())
        } else {
            text.append(code, font: font, style: TextRunStyle())
        }
        text.setTabInterval(style.codeTabInterval, in: NSRange(location: 0, length: text.length))
        return text
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
