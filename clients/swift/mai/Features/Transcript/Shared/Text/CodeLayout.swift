import CoreGraphics
import Foundation

/// A fenced code block: a header with its language, then one line per
/// source line, never wrapped. The height is analytic (header + lines ×
/// line height + inset), so it never changes when colors arrive; the width
/// is the longest line, scrolled horizontally when wider than the row.
nonisolated struct CodeLayout: Sendable {
    /// Materialized `TextLayout` for normal code blocks (`<= 16 KB`), or
    /// 2D-virtualized on-demand index for extreme vertical or horizontal blocks.
    enum Body: Sendable {
        case materialized(TextLayout)
        case virtualized(VirtualCodeBody)
    }

    /// Above this UTF-8 size (or if any single line exceeds `virtualizeLineLimit`),
    /// code blocks use 2D-virtualized on-demand tile shaping instead of
    /// materializing every glyph up front.
    static let virtualizeByteLimit = 16_384
    static let virtualizeLineLimit = 4_096

    let label: TextLayout
    let storage: Body
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
    /// True when `storage` was built by `MonospaceASCIIMetrics.materializeASCII`
    /// rather than Core Text, so incremental Core Text suffix layout only runs
    /// on Core Text prefixes.
    let usedASCIIFastPath: Bool

    /// Materialized body when non-virtualized (nil for 2D-virtualized code).
    var materializedBody: TextLayout? {
        if case .materialized(let layout) = storage { return layout }
        return nil
    }

    var bodySize: CGSize {
        switch storage {
        case .materialized(let layout): layout.size
        case .virtualized(let virtual): virtual.size
        }
    }

    var utf16Length: Int {
        switch storage {
        case .materialized(let layout): layout.length
        case .virtualized(let virtual): virtual.totalUTF16
        }
    }

    var retainedBytes: Int {
        let bodyBytes: Int =
            switch storage {
            case .materialized(let layout): layout.retainedBytes
            case .virtualized(let virtual): virtual.retainedBytes
            }
        return bodyBytes + label.retainedBytes
    }

    var isHighlighted: Bool { colors != nil }

    var hasLargeNonASCIILine: Bool {
        if case .virtualized(let virtual) = storage { return virtual.hasLargeNonASCIILine }
        return false
    }

    /// The theme its syntax colors are for (dark or not); nil while plain.
    var colorsAreDark: Bool? { colors?.isDark }

    var isWiderThanBlock: Bool { contentWidth > size.width + 0.5 }

    static func make(
        code: String, language: String?, colors: CodeColors?, width: CGFloat, style: TextStyle,
        previous: CodeLayout? = nil
    ) -> CodeLayout {
        let colors = colors?.code == code ? colors : nil
        let display = displayName(language)
        let label =
            previous.flatMap { $0.label.string == display ? $0.label : nil }
            ?? TextLayoutEngine.layout(
                AttributedTextBuilder.plain(display, role: .callout, color: .secondary, style: style),
                width: .greatestFiniteMagnitude, options: .init(lineSpacing: 0))
        let ascii = MonospaceASCIIMetrics.metrics(for: style.font(.code))
        let storage: Body
        let bodyWidth: CGFloat
        let usedASCIIFastPath: Bool
        if shouldVirtualize(code) {
            let virtual = VirtualCodeBody(code: code, style: style, colors: colors, ascii: ascii)
            storage = .virtualized(virtual)
            bodyWidth = virtual.size.width
            usedASCIIFastPath = false
        } else if colors == nil, let fast = ascii.materializeASCII(code: code, style: style) {
            storage = .materialized(fast)
            bodyWidth = fast.size.width
            usedASCIIFastPath = true
        } else {
            let bodyOptions = TextLayoutEngine.Options(lineSpacing: 0, wraps: false, fixedLineHeight: style.codeLineHeight)
            var incremental: TextLayout?
            if colors == nil, let previous, previous.colors == nil, !previous.code.isEmpty,
                case .materialized(let prevBody) = previous.storage,
                !previous.usedASCIIFastPath,
                code.hasPrefix(previous.code), prevBody.lines.count >= 3, !prevBody.hasComplexBiDi
            {
                let keepCount = prevBody.lines.count - 1
                let resumeUTF16 = prevBody.lines[keepCount].range.lowerBound
                let utf16 = code.utf16
                if resumeUTF16 > 0, resumeUTF16 < utf16.count {
                    let startIdx = utf16.index(utf16.startIndex, offsetBy: resumeUTF16)
                    let suffixText = buildStyledCode(String(code[startIdx...]), colors: nil, style: style)
                    incremental = TextLayoutEngine.layoutSuffix(
                        fullString: code, suffix: suffixText, width: .greatestFiniteMagnitude,
                        options: bodyOptions, appendingTo: prevBody, keepCount: keepCount)
                }
            }
            let body =
                incremental
                ?? TextLayoutEngine.layout(
                    buildStyledCode(code, colors: colors, style: style), width: .greatestFiniteMagnitude,
                    options: bodyOptions)
            storage = .materialized(body)
            bodyWidth = body.size.width
            usedASCIIFastPath = false
        }
        let headerHeight = style.codeHeaderHeight
        let contentWidth = ceil(bodyWidth + 2 * style.codeHorizontalInset)
        let height = Self.height(for: code, style: style)
        return CodeLayout(
            label: label, storage: storage, code: code, headerHeight: headerHeight, labelTop: style.codeHeaderTopInset,
            bodyOrigin: CGPoint(x: style.codeHorizontalInset, y: headerHeight),
            size: CGSize(width: width, height: height), contentWidth: contentWidth, colors: colors,
            usedASCIIFastPath: usedASCIIFastPath)
    }

    private static func shouldVirtualize(_ code: String) -> Bool {
        let count = code.utf8.count
        if count > virtualizeByteLimit { return true }
        guard count > virtualizeLineLimit else { return false }
        var run = 0
        for byte in code.utf8 {
            if byte == 0x0A {
                run = 0
            } else {
                run += 1
                if run > virtualizeLineLimit { return true }
            }
        }
        return false
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

    /// The same block at another row width: code never wraps, so its text
    /// layout is the same and only the block's width changes.
    func resized(toWidth width: CGFloat) -> CodeLayout {
        CodeLayout(
            label: label, storage: storage, code: code, headerHeight: headerHeight, labelTop: labelTop,
            bodyOrigin: bodyOrigin, size: CGSize(width: width, height: size.height), contentWidth: contentWidth,
            colors: colors, usedASCIIFastPath: usedASCIIFastPath)
    }

    func drawBody(at origin: CGPoint, clip: CGRect, palette: TextPalette, in context: CGContext) {
        switch storage {
        case .materialized(let layout):
            TextRenderer.draw(layout, at: origin, clip: clip, palette: palette, in: context)
        case .virtualized(let virtual):
            virtual.draw(at: origin, clip: clip, palette: palette, in: context)
        }
    }

    func offset(closestTo local: CGPoint) -> Int {
        switch storage {
        case .materialized(let layout): layout.offset(closestTo: local)
        case .virtualized(let virtual): virtual.offset(closestTo: local)
        }
    }

    func strictOffset(at local: CGPoint) -> Int? {
        switch storage {
        case .materialized(let layout):
            guard CGRect(origin: .zero, size: layout.size).contains(local),
                let lineIdx = layout.lineIndex(nearestY: local.y)
            else { return nil }
            let line = layout.lines[lineIdx]
            guard local.y >= line.top, local.y <= line.bottom,
                local.x >= line.x, local.x <= line.x + line.width
            else { return nil }
            return layout.offset(closestTo: local)
        case .virtualized(let virtual):
            return virtual.strictOffset(at: local)
        }
    }

    func selectionRects(for range: Range<Int>) -> [CGRect] {
        switch storage {
        case .materialized(let layout): layout.selectionRects(for: range)
        case .virtualized(let virtual): virtual.selectionRects(for: range)
        }
    }

    func caretRect(for utf16Offset: Int) -> CGRect? {
        switch storage {
        case .materialized(let layout):
            guard let line = layout.lines.last(where: { $0.range.lowerBound <= utf16Offset }) else { return nil }
            let x = line.caretOffsets[min(utf16Offset - line.range.lowerBound, line.caretOffsets.count - 1)]
            return CGRect(x: x, y: line.top, width: 2, height: line.height)
        case .virtualized(let virtual):
            return virtual.caretRect(for: utf16Offset)
        }
    }

    func unchangedBodyHeight(comparedTo other: CodeLayout) -> CGFloat {
        switch (storage, other.storage) {
        case (.materialized(let a), .materialized(let b)):
            return RowContentDiff.unchangedHeight(a, b)
        case (.virtualized(let a), .virtualized(let b)):
            return a.unchangedHeight(comparedTo: b)
        default:
            return 0
        }
    }

    static func buildStyledCode(_ code: String, colors: CodeColors?, style: TextStyle) -> StyledText {
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
