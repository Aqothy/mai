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
        let nsString = text.string.mutableString
        var builder = Builder(text: text, nsString: nsString, options: options, availableWidth: width)
        var start = 0
        var paragraphIndex = 0
        while start < length {
            while paragraphIndex + 1 < text.paragraphs.count, text.paragraphs[paragraphIndex + 1].start <= start {
                paragraphIndex += 1
            }
            let paragraph = text.paragraphs.isEmpty ? nil : text.paragraphs[paragraphIndex]
            let isParagraphStart = paragraph.map { $0.start == start } ?? (start == 0)
            let indent = (isParagraphStart ? paragraph?.firstLineIndent : paragraph?.headIndent) ?? 0
            let count = nextLineLength(
                typesetter: typesetter, nsString: nsString, start: start, length: length,
                availableWidth: max(1, width - indent), wraps: options.wraps)
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            builder.add(
                line, range: start..<(start + count), indent: indent, paragraph: paragraph,
                isParagraphStart: isParagraphStart,
                endsWithNewline: nsString.character(at: start + count - 1) == 0x0A)
            start += count
        }
        return builder.finish()
    }

    /// Incremental layout for a growing block (streaming prose or code): keeps
    /// the finished lines of `previous` before `unchangedUTF16Prefix` (with a
    /// 1-line wrap margin for wrapped prose) and only invokes Core Text on the
    /// changed suffix. Falls back to full layout for BiDi text or when too few
    /// lines can be kept.
    static func layout(
        _ text: StyledText, width: CGFloat, options: Options, appendingTo previous: TextLayout,
        unchangedUTF16Prefix: Int
    ) -> TextLayout {
        guard !previous.hasComplexBiDi, !previous.lines.isEmpty, text.length > 0, text.paragraphs.count <= 1 else {
            return layout(text, width: width, options: options)
        }
        // Keep lines strictly before the unchanged prefix; for wrapped text,
        // back up one extra line so a growing word on the boundary re-breaks.
        var keepCount = 0
        while keepCount < previous.lines.count, previous.lines[keepCount].range.upperBound <= unchangedUTF16Prefix {
            keepCount += 1
        }
        if options.wraps { keepCount = max(0, keepCount - 1) }
        guard keepCount >= 2, keepCount < previous.lines.count else {
            return layout(text, width: width, options: options)
        }
        let resumeLine = previous.lines[keepCount]
        let resumeUTF16 = resumeLine.range.lowerBound
        guard resumeUTF16 > 0, resumeUTF16 < text.length else {
            return layout(text, width: width, options: options)
        }

        // Build a suffix `StyledText` for `[resumeUTF16..<text.length]` so
        // Core Text only typesets the few newly changed lines.
        let suffixLength = text.length - resumeUTF16
        let suffixAttributed = text.string.attributedSubstring(from: NSRange(location: resumeUTF16, length: suffixLength))
        let typesetter = CTTypesetterCreateWithAttributedString(suffixAttributed)
        let suffixNS = suffixAttributed.string as NSString
        let paragraph = text.paragraphs.first
        let indent = paragraph?.headIndent ?? 0
        let lastKept = previous.lines[keepCount - 1]
        let keptRunEnd = resumeLine.runs.lowerBound
        let keptY = lastKept.bottom

        var builder = Builder(
            text: text, nsString: suffixNS, options: options, availableWidth: width,
            initialLines: Array(previous.lines[..<keepCount]),
            initialRuns: Array(previous.runs[..<keptRunEnd]),
            initialDecorations: previous.decorations.filter { $0.rect.midY <= keptY },
            initialY: keptY,
            initialWidth: previous.lines[..<keepCount].reduce(CGFloat(0)) { max($0, $1.x + $1.width) },
            previousQuoteBars: paragraph?.quoteBars ?? [],
            utf16BaseOffset: resumeUTF16)

        var localStart = 0
        while localStart < suffixLength {
            let count = nextLineLength(
                typesetter: typesetter, nsString: suffixNS, start: localStart, length: suffixLength,
                availableWidth: max(1, width - indent), wraps: options.wraps)
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: localStart, length: count))
            builder.add(
                line, range: localStart..<(localStart + count), indent: indent, paragraph: paragraph,
                isParagraphStart: false,
                endsWithNewline: suffixNS.character(at: localStart + count - 1) == 0x0A)
            localStart += count
        }
        // If complex BiDi appeared in the suffix, recompute cleanly so
        // paragraph-level BiDi ordering matches one-shot layout.
        if builder.hasComplexBiDi {
            return layout(text, width: width, options: options)
        }
        return builder.finish()
    }

    /// Measure-only height of `text` at `width` (for off-screen background
    /// sweep): breaks lines and sums metrics without copying glyphs, positions,
    /// carets or decorations.
    static func measureHeight(_ text: StyledText, width: CGFloat, options: Options) -> CGFloat {
        let length = text.length
        guard length > 0 else { return 0 }
        let typesetter = CTTypesetterCreateWithAttributedString(text.string)
        let nsString = text.string.mutableString
        var y: CGFloat = 0
        var hasLines = false
        var start = 0
        var paragraphIndex = 0
        while start < length {
            while paragraphIndex + 1 < text.paragraphs.count, text.paragraphs[paragraphIndex + 1].start <= start {
                paragraphIndex += 1
            }
            let paragraph = text.paragraphs.isEmpty ? nil : text.paragraphs[paragraphIndex]
            let isParagraphStart = paragraph.map { $0.start == start } ?? (start == 0)
            let indent = (isParagraphStart ? paragraph?.firstLineIndent : paragraph?.headIndent) ?? 0
            let count = nextLineLength(
                typesetter: typesetter, nsString: nsString, start: start, length: length,
                availableWidth: max(1, width - indent), wraps: options.wraps)
            if hasLines {
                y += options.lineSpacing + (isParagraphStart ? paragraph?.spacingBefore ?? 0 : 0)
            }
            if let fixed = options.fixedLineHeight {
                y += fixed
            } else {
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                y += ceil(ascent + descent + leading)
            }
            hasLines = true
            start += count
        }
        return ceil(y)
    }

    /// The UTF-16 length of the line starting at `start`: Core Text's break
    /// when wrapping, through the next newline when not.
    private static func nextLineLength(
        typesetter: CTTypesetter, nsString: NSString, start: Int, length: Int, availableWidth: CGFloat, wraps: Bool
    ) -> Int {
        var count: Int
        if wraps {
            count = CTTypesetterSuggestLineBreak(typesetter, start, Double(availableWidth))
        } else {
            var cursor = start
            while cursor < length, nsString.character(at: cursor) != 0x0A { cursor += 1 }
            count = cursor < length ? cursor - start + 1 : length - start
        }
        return max(1, min(count, length - start))
    }

    /// Accumulates lines, runs and decorations.
    private struct Builder {
        private static let fontKey = kCTFontAttributeName as String

        let text: StyledText
        let nsString: NSString
        let options: Options
        let availableWidth: CGFloat
        /// Where `nsString` starts in the layout's text: a suffix laid out
        /// after kept lines (incremental layout) ranges from there.
        let utf16BaseOffset: Int
        var lines: [TextLine]
        var runs: [TextGlyphRun]
        var decorations: [TextDecoration]
        var y: CGFloat
        var width: CGFloat
        var previousQuoteBars: [CGFloat]
        var hasComplexBiDi = false

        init(
            text: StyledText, nsString: NSString, options: Options, availableWidth: CGFloat,
            initialLines: [TextLine] = [], initialRuns: [TextGlyphRun] = [],
            initialDecorations: [TextDecoration] = [], initialY: CGFloat = 0, initialWidth: CGFloat = 0,
            previousQuoteBars: [CGFloat] = [], utf16BaseOffset: Int = 0
        ) {
            self.text = text
            self.nsString = nsString
            self.options = options
            self.availableWidth = availableWidth
            self.utf16BaseOffset = utf16BaseOffset
            lines = initialLines
            runs = initialRuns
            decorations = initialDecorations
            y = initialY
            width = initialWidth
            self.previousQuoteBars = previousQuoteBars
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
            let carets = addRunsAndCarets(of: line, range: range, indent: indent, baseline: baseline, width: lineWidth)
            let textRange = (range.lowerBound + utf16BaseOffset)..<(range.upperBound + utf16BaseOffset)
            lines.append(
                TextLine(
                    top: y, baseline: baseline, height: height, x: indent, width: lineWidth, range: textRange,
                    caretOffsets: carets, runs: firstRun..<runs.count, endsWithNewline: endsWithNewline))
            if let paragraph {
                addParagraphDecorations(paragraph, lineHeight: height, gapAbove: gapAbove)
            }
            width = max(width, indent + lineWidth)
            y += height
        }

        func finish() -> TextLayout {
            TextLayout(
                string: text.string.string, size: CGSize(width: ceil(width), height: ceil(y)), lines: lines,
                runs: runs, decorations: decorations, links: text.links, hasComplexBiDi: hasComplexBiDi)
        }

        /// Copies the line's runs and their decorations, and returns its
        /// carets, in one pass over Core Text's own glyph buffers.
        private mutating func addRunsAndCarets(
            of line: CTLine, range: Range<Int>, indent: CGFloat, baseline: CGFloat, width: CGFloat
        ) -> [CGFloat] {
            let ctRuns = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
            let needsCoreTextCarets = ctRuns.contains(where: Self.needsCoreTextCarets)
            if needsCoreTextCarets { hasComplexBiDi = true }
            var carets = needsCoreTextCarets ? [] : [CGFloat](repeating: .nan, count: range.count + 1)
            let rangeStart = range.lowerBound

            for run in ctRuns {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let fontValue = attributes[Self.fontKey] as CFTypeRef?,
                    CFGetTypeID(fontValue) == CTFontGetTypeID()
                else { continue }
                let font = TranscriptFont(font: unsafeDowncast(fontValue, to: CTFont.self))
                let styleIndex = (attributes[StyledText.styleKey.rawValue] as? NSNumber)?.intValue ?? 0
                let style = text.styles.indices.contains(styleIndex) ? text.styles[styleIndex] : TextRunStyle()

                let glyphs: [CGGlyph]
                if let pointer = CTRunGetGlyphsPtr(run) {
                    glyphs = Array(UnsafeBufferPointer(start: pointer, count: count))
                } else {
                    var buffer = [CGGlyph](repeating: 0, count: count)
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &buffer)
                    glyphs = buffer
                }
                // Carets come from the same positions in the same pass. The
                // run keeps them as `CTFontDrawGlyphs` takes them under the
                // renderer's flipped text matrix: y negated, from the baseline.
                let stringRange = CTRunGetStringRange(run)
                let positions = Self.withRunPositions(run, count: count) { positions in
                    if !needsCoreTextCarets {
                        Self.accumulateRunCarets(
                            run: run, count: count, positions: positions, stringRange: stringRange,
                            rangeStart: rangeStart, nsString: nsString, indent: indent, into: &carets)
                    }
                    return positions.map { CGPoint(x: indent + $0.x, y: $0.y - baseline) }
                }

                runs.append(
                    TextGlyphRun(
                        font: font, glyphs: glyphs, positions: positions, color: style.color,
                        range: (stringRange.location + utf16BaseOffset)..<(
                            stringRange.location + utf16BaseOffset + stringRange.length),
                        linkIndex: style.linkIndex))
                addRunDecorations(run, style: style, font: font, start: positions[0].x, baseline: baseline)
            }

            if needsCoreTextCarets {
                return TextLayoutEngine.enumeratedCaretOffsets(
                    of: line, range: range, string: nsString, indent: indent, width: width)
            }
            return TextLayoutEngine.filled(carets, indent: indent, width: width)
        }

        /// Right-to-left runs, and runs Core Text reordered, take Core Text's
        /// carets (`caretOffsets`).
        static func needsCoreTextCarets(_ run: CTRun) -> Bool {
            !CTRunGetStatus(run).isDisjoint(with: [.rightToLeft, .nonMonotonic])
        }

        /// Core Text's own positions when it has them in a buffer (usually),
        /// a copy otherwise; valid only inside `body`.
        static func withRunPositions<R>(_ run: CTRun, count: Int, _ body: (UnsafeBufferPointer<CGPoint>) -> R) -> R {
            if let pointer = CTRunGetPositionsPtr(run) { return body(UnsafeBufferPointer(start: pointer, count: count)) }
            var buffer = [CGPoint](repeating: .zero, count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &buffer)
            return buffer.withUnsafeBufferPointer(body)
        }

        private static func withRunStringIndices<R>(
            _ run: CTRun, count: Int, _ body: (UnsafeBufferPointer<CFIndex>) -> R
        ) -> R {
            if let pointer = CTRunGetStringIndicesPtr(run) {
                return body(UnsafeBufferPointer(start: pointer, count: count))
            }
            var buffer = [CFIndex](repeating: 0, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &buffer)
            return buffer.withUnsafeBufferPointer(body)
        }

        private static func withRunAdvances<R>(_ run: CTRun, count: Int, _ body: (UnsafeBufferPointer<CGSize>) -> R) -> R {
            if let pointer = CTRunGetAdvancesPtr(run) { return body(UnsafeBufferPointer(start: pointer, count: count)) }
            var buffer = [CGSize](repeating: .zero, count: count)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &buffer)
            return buffer.withUnsafeBufferPointer(body)
        }

        /// The carets of `run`'s characters (see `caretOffsets`), into
        /// `offsets` indexed from `rangeStart`.
        static func accumulateRunCarets(
            run: CTRun, count: Int, positions: UnsafeBufferPointer<CGPoint>, stringRange: CFRange,
            rangeStart: Int, nsString: NSString, indent: CGFloat, into offsets: inout [CGFloat]
        ) {
            withRunStringIndices(run, count: count) { indicesPtr in
                let runEnd = stringRange.location + stringRange.length
                var glyph = 0
                while glyph < count {
                    let first = indicesPtr[glyph]
                    // A character drawn as several glyphs carets at its first.
                    var nextGlyph = glyph + 1
                    while nextGlyph < count, indicesPtr[nextGlyph] == first { nextGlyph += 1 }
                    let end = nextGlyph < count ? indicesPtr[nextGlyph] : runEnd
                    if end > first {
                        let span = end - first
                        var isLigature = false
                        if span > 1 {
                            isLigature = true
                            for idx in first..<end {
                                let unit = nsString.character(at: idx)
                                if unit >= 0x80 || unit == 0x0D || unit == 0x0A {
                                    isLigature = false
                                    break
                                }
                            }
                        }
                        let width = isLigature ? withRunAdvances(run, count: count) { $0[glyph].width } : 0
                        let baseX = indent + positions[glyph].x
                        for index in first..<end {
                            let position = index - rangeStart
                            guard offsets.indices.contains(position), offsets[position].isNaN else { continue }
                            let share = isLigature ? width * CGFloat(index - first) / CGFloat(span) : 0
                            offsets[position] = baseX + share
                        }
                    }
                    glyph = nextGlyph
                }
            }
        }

        private mutating func addRunDecorations(
            _ run: CTRun, style: TextRunStyle, font: TranscriptFont, start: CGFloat, baseline: CGFloat
        ) {
            guard style.isInlineCode || style.isUnderlined || style.isStruck else { return }
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let runWidth = CGFloat(
                CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil))
            let thickness = max(1, CTFontGetUnderlineThickness(font.font))
            if style.isInlineCode {
                decorations.append(
                    TextDecoration(
                        kind: .inlineCodeBackground,
                        rect: CGRect(
                            x: start - 3, y: baseline - ascent - 1, width: runWidth + 6, height: ascent + descent + 2),
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
    }

    /// The caret x before each UTF-16 offset of `line`, and after its last.
    /// From the glyph positions the line already has: a character's caret
    /// is the left edge of the glyph that starts it, the letters of an ASCII
    /// ligature share its width, and the rest of a cluster (an emoji
    /// sequence, a combining mark) carets with its start, so hit testing
    /// never lands inside it. Right-to-left lines, and lines whose glyphs
    /// Core Text reordered (an Indic vowel sign drawn before its consonant),
    /// ask Core Text, which knows visual order but looks every character's
    /// cluster up: most of the layout time of code and long paragraphs.
    static func caretOffsets(
        of line: CTLine, range: Range<Int>, string: NSString, indent: CGFloat, width: CGFloat
    ) -> [CGFloat] {
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        if runs.contains(where: Builder.needsCoreTextCarets) {
            return enumeratedCaretOffsets(of: line, range: range, string: string, indent: indent, width: width)
        }
        var offsets = [CGFloat](repeating: .nan, count: range.count + 1)
        let start = range.lowerBound
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            Builder.withRunPositions(run, count: count) { positions in
                Builder.accumulateRunCarets(
                    run: run, count: count, positions: positions, stringRange: CTRunGetStringRange(run),
                    rangeStart: start, nsString: string, indent: indent, into: &offsets)
            }
        }
        return filled(offsets, indent: indent, width: width)
    }

    /// Core Text's own caret offsets, for right-to-left and reordered lines
    /// (and to check the glyph-based ones against). It reports both edges of
    /// every character in visual order; the leading edge is the caret before
    /// it, the trailing edge the caret after its whole cluster (with
    /// `string`), so an emoji's second UTF-16 unit never gets a caret.
    static func enumeratedCaretOffsets(
        of line: CTLine, range: Range<Int>, string: NSString? = nil, indent: CGFloat, width: CGFloat
    ) -> [CGFloat] {
        var offsets = [CGFloat](repeating: .nan, count: range.count + 1)
        let start = range.lowerBound
        CTLineEnumerateCaretOffsets(line) { offset, index, leadingEdge, _ in
            let position: Int
            if leadingEdge {
                position = index - start
            } else if let string, index < string.length {
                position = NSMaxRange(string.rangeOfComposedCharacterSequence(at: index)) - start
            } else {
                position = index - start + 1
            }
            guard offsets.indices.contains(position) else { return }
            if leadingEdge || offsets[position].isNaN { offsets[position] = indent + CGFloat(offset) }
        }
        return filled(offsets, indent: indent, width: width)
    }

    /// Offsets without a caret of their own take the one before; the end of
    /// the line is at least its width.
    private static func filled(_ offsets: [CGFloat], indent: CGFloat, width: CGFloat) -> [CGFloat] {
        var offsets = offsets
        var last = indent
        for index in offsets.indices {
            if offsets[index].isNaN { offsets[index] = index == offsets.count - 1 ? max(last, indent + width) : last }
            last = offsets[index]
        }
        return offsets
    }
}
