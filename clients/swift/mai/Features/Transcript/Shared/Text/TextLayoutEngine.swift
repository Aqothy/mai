import CoreText
import CoreGraphics
import Foundation

/// Lays `StyledText` out with Core Text and copies the result into a
/// `TextLayout`. A pure function of its inputs, safe on any thread: the
/// typesetter, lines and runs it makes stay inside the call (Apple's Core
/// Text overview: layout objects belong to one operation, queue or thread).
///
/// Lines are broken with `CTTypesetterSuggestLineBreak` and placed by hand,
/// so paragraph spacing, indents and line spacing are exactly the chat's,
/// and one call serves measuring, drawing, hit testing and selection.
nonisolated enum TextLayoutEngine {
    struct Options {
        var lineSpacing: CGFloat
        /// Code never wraps; each source line is one line.
        var wraps = true
        /// Every line this tall instead of its own metrics (code).
        var fixedLineHeight: CGFloat?
        var quoteBarWidth: CGFloat = 3
    }

    static func layout(_ text: StyledText, width: CGFloat, options: Options) -> TextLayout {
        let length = text.length
        guard length > 0 else { return .empty }
        let typesetter = CTTypesetterCreateWithAttributedString(text.string)
        var builder = Builder(text: text, options: options, availableWidth: width)
        var start = 0
        var paragraphIndex = 0
        while start < length {
            while paragraphIndex + 1 < text.paragraphs.count, text.paragraphs[paragraphIndex + 1].start <= start {
                paragraphIndex += 1
            }
            let paragraph = text.paragraphs.isEmpty ? nil : text.paragraphs[paragraphIndex]
            let isParagraphStart = paragraph.map { $0.start == start } ?? (start == 0)
            let indent = (isParagraphStart ? paragraph?.firstLineIndent : paragraph?.headIndent) ?? 0
            var count: Int
            if options.wraps {
                count = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width - indent)))
            } else {
                count = (start..<length).first { text.string.mutableString.character(at: $0) == 0x0A }
                    .map { $0 - start + 1 } ?? (length - start)
            }
            count = max(1, min(count, length - start))
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            builder.add(
                line, range: start..<(start + count), indent: indent, paragraph: paragraph,
                isParagraphStart: isParagraphStart,
                endsWithNewline: text.string.mutableString.character(at: start + count - 1) == 0x0A)
            start += count
        }
        return builder.finish()
    }

    /// Accumulates lines, runs and decorations.
    private struct Builder {
        let text: StyledText
        let options: Options
        let availableWidth: CGFloat
        var lines: [TextLine] = []
        var runs: [TextGlyphRun] = []
        var decorations: [TextDecoration] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var previousQuoteBars: [CGFloat] = []

        init(text: StyledText, options: Options, availableWidth: CGFloat) {
            self.text = text
            self.options = options
            self.availableWidth = availableWidth
        }

        mutating func add(
            _ line: CTLine, range: Range<Int>, indent: CGFloat, paragraph: StyledParagraph?,
            isParagraphStart: Bool, endsWithNewline: Bool
        ) {
            let gapAbove: CGFloat
            if lines.isEmpty {
                gapAbove = 0
            } else {
                gapAbove = options.lineSpacing + (isParagraphStart ? paragraph?.spacingBefore ?? 0 : 0)
            }
            y += gapAbove
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let typographicWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let lineWidth = max(0, typographicWidth - CGFloat(CTLineGetTrailingWhitespaceWidth(line)))
            let height = options.fixedLineHeight ?? ceil(ascent + descent + leading)
            let baseline = y + (options.fixedLineHeight.map { ($0 - ascent - descent) / 2 } ?? 0) + ascent
            let firstRun = runs.count
            addRuns(of: line, indent: indent, baseline: baseline)
            lines.append(
                TextLine(
                    top: y, baseline: baseline, height: height, x: indent, width: lineWidth, range: range,
                    caretOffsets: caretOffsets(of: line, range: range, indent: indent, width: lineWidth),
                    runs: firstRun..<runs.count, endsWithNewline: endsWithNewline))
            if let paragraph {
                addParagraphDecorations(paragraph, lineHeight: height, gapAbove: gapAbove)
            }
            width = max(width, indent + lineWidth)
            y += height
        }

        func finish() -> TextLayout {
            TextLayout(
                string: text.string.string, size: CGSize(width: ceil(width), height: ceil(y)), lines: lines,
                runs: runs, decorations: decorations, links: text.links)
        }

        private mutating func addRuns(of line: CTLine, indent: CGFloat, baseline: CGFloat) {
            let fontKey = kCTFontAttributeName as String
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let fontValue = attributes[fontKey] as CFTypeRef?,
                    CFGetTypeID(fontValue) == CTFontGetTypeID()
                else { continue }
                let font = TranscriptFont(font: unsafeDowncast(fontValue, to: CTFont.self))
                let styleIndex = (attributes[StyledText.styleKey.rawValue] as? NSNumber)?.intValue ?? 0
                let style = text.styles.indices.contains(styleIndex) ? text.styles[styleIndex] : TextRunStyle()
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                for index in positions.indices {
                    positions[index] = CGPoint(x: indent + positions[index].x, y: baseline - positions[index].y)
                }
                let stringRange = CTRunGetStringRange(run)
                runs.append(
                    TextGlyphRun(
                        font: font, glyphs: glyphs, positions: positions, color: style.color,
                        range: stringRange.location..<(stringRange.location + stringRange.length),
                        linkIndex: style.linkIndex))
                addRunDecorations(run, style: style, font: font, start: positions[0].x, baseline: baseline)
            }
        }

        private mutating func addRunDecorations(
            _ run: CTRun, style: TextRunStyle, font: TranscriptFont, start: CGFloat, baseline: CGFloat
        ) {
            guard style.isInlineCode || style.isUnderlined || style.isStruck else { return }
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let runWidth = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil))
            let thickness = max(1, CTFontGetUnderlineThickness(font.font))
            if style.isInlineCode {
                decorations.append(
                    TextDecoration(
                        kind: .inlineCodeBackground,
                        rect: CGRect(x: start - 3, y: baseline - ascent - 1, width: runWidth + 6, height: ascent + descent + 2),
                        color: .primary))
            }
            if style.isUnderlined {
                decorations.append(
                    TextDecoration(
                        kind: .underline,
                        rect: CGRect(
                            x: start, y: baseline - CTFontGetUnderlinePosition(font.font), width: runWidth,
                            height: thickness),
                        color: style.color))
            }
            if style.isStruck {
                decorations.append(
                    TextDecoration(
                        kind: .strikethrough,
                        rect: CGRect(
                            x: start, y: baseline - CTFontGetXHeight(font.font) / 2 - thickness / 2, width: runWidth,
                            height: thickness),
                        color: style.color))
            }
        }

        /// Quote bars run beside every line of a quoted paragraph and through
        /// the gap above it when the paragraph before shares them; a rule is
        /// a hairline across the paragraph's width.
        private mutating func addParagraphDecorations(
            _ paragraph: StyledParagraph, lineHeight: CGFloat, gapAbove: CGFloat
        ) {
            for bar in paragraph.quoteBars {
                let joinsAbove = previousQuoteBars.contains(bar)
                decorations.append(
                    TextDecoration(
                        kind: .quoteBar,
                        rect: CGRect(
                            x: bar, y: y - (joinsAbove ? gapAbove : 0), width: options.quoteBarWidth,
                            height: lineHeight + (joinsAbove ? gapAbove : 0)),
                        color: .tertiary))
            }
            previousQuoteBars = paragraph.quoteBars
            if paragraph.isRule {
                decorations.append(
                    TextDecoration(
                        kind: .rule,
                        rect: CGRect(
                            x: paragraph.firstLineIndent, y: (y + lineHeight / 2).rounded(.down),
                            width: max(0, availableWidth - paragraph.firstLineIndent), height: 1),
                        color: .tertiary))
            }
        }

        /// The caret x before each UTF-16 offset of the line, and after its
        /// last. Core Text reports both edges of every character in visual
        /// order; the leading edge of a character is the caret before it.
        private func caretOffsets(of line: CTLine, range: Range<Int>, indent: CGFloat, width: CGFloat) -> [CGFloat] {
            var offsets = [CGFloat](repeating: .nan, count: range.count + 1)
            let start = range.lowerBound
            CTLineEnumerateCaretOffsets(line) { offset, index, leadingEdge, _ in
                let position = index - start + (leadingEdge ? 0 : 1)
                guard offsets.indices.contains(position) else { return }
                if leadingEdge || offsets[position].isNaN { offsets[position] = indent + CGFloat(offset) }
            }
            var last = indent
            for index in offsets.indices {
                if offsets[index].isNaN { offsets[index] = index == offsets.count - 1 ? max(last, indent + width) : last }
                last = offsets[index]
            }
            return offsets
        }
    }
}
