import Markdown

/// Converts active or remote Markdown nodes into inert code for renderers that
/// need sanitized source. Ordinary Markdown stays on the unchanged fast path.
nonisolated enum ChatMarkdownSourceSanitizer {
    static func sanitize(_ source: String) -> String {
        guard source.contains("<") || source.contains("![") else {
            return source
        }

        let document = Markdown.Document(parsing: source)
        var collector = ReplacementCollector(source: source)
        collector.visit(document)
        return collector.result
    }
}

private nonisolated struct ReplacementCollector: MarkupWalker {
    private struct Replacement {
        let range: Range<Int>
        let text: String
    }

    private let sourceBytes: [UInt8]
    private let lineStartOffsets: [Int]
    private var replacements: [Replacement] = []

    init(source: String) {
        sourceBytes = Array(source.utf8)

        var lineStartOffsets = [0]
        for (offset, byte) in sourceBytes.enumerated() where byte == 0x0A {
            lineStartOffsets.append(offset + 1)
        }
        self.lineStartOffsets = lineStartOffsets
    }

    var result: String {
        var bytes = sourceBytes
        for replacement in replacements.sorted(
            by: { $0.range.lowerBound > $1.range.lowerBound }
        ) {
            bytes.replaceSubrange(replacement.range, with: replacement.text.utf8)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) {
        addReplacement(
            for: htmlBlock,
            text: Self.fencedHTML(htmlBlock.rawHTML)
        )
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        addReplacement(
            for: inlineHTML,
            text: Self.inlineCode(inlineHTML.rawHTML)
        )
    }

    mutating func visitImage(_ image: Markdown.Image) {
        guard let range = byteRange(for: image) else { return }
        let originalSource = String(
            decoding: sourceBytes[range],
            as: UTF8.self
        )
        replacements.append(
            Replacement(range: range, text: Self.inlineCode(originalSource))
        )
    }

    private mutating func addReplacement(
        for markup: some Markup,
        text: String
    ) {
        guard let range = byteRange(for: markup) else { return }
        replacements.append(Replacement(range: range, text: text))
    }

    private func byteRange(for markup: some Markup) -> Range<Int>? {
        guard
            let sourceRange = markup.range,
            let lowerBound = byteOffset(for: sourceRange.lowerBound),
            let upperBound = byteOffset(for: sourceRange.upperBound),
            lowerBound <= upperBound
        else {
            return nil
        }
        return lowerBound..<upperBound
    }

    private func byteOffset(for location: SourceLocation) -> Int? {
        let lineIndex = location.line - 1
        guard lineStartOffsets.indices.contains(lineIndex) else { return nil }

        let offset = lineStartOffsets[lineIndex] + location.column - 1
        guard
            sourceBytes.indices.contains(offset)
                || offset == sourceBytes.endIndex
        else {
            return nil
        }
        return offset
    }

    private static func fencedHTML(_ html: String) -> String {
        let fence = delimiter(
            byte: 0x7E,
            minimumLength: 3,
            avoiding: html
        )
        let trailingNewline = html.hasSuffix("\n") ? "" : "\n"
        return "\(fence)html\n\(html)\(trailingNewline)\(fence)"
    }

    private static func inlineCode(_ source: String) -> String {
        let delimiter = delimiter(
            byte: 0x60,
            minimumLength: 1,
            avoiding: source
        )
        return "\(delimiter) \(source) \(delimiter)"
    }

    private static func delimiter(
        byte: UInt8,
        minimumLength: Int,
        avoiding source: String
    ) -> String {
        var longestRun = 0
        var currentRun = 0
        for sourceByte in source.utf8 {
            if sourceByte == byte {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }

        return String(
            repeating: Character(UnicodeScalar(byte)),
            count: max(minimumLength, longestRun + 1)
        )
    }
}
