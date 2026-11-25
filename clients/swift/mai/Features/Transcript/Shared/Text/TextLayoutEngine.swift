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
        /// Right-align RTL paragraphs (`dir="auto"`) to `availableWidth`;
        /// disabled for shrink-wrapped user bubbles so short Arabic prompts
        /// stay compact.
        var alignsRTLToWidth = true
    }

    /// Core Text lays a string longer than 10,240 UTF-16 units out another
    /// way: without kerning or ligatures, and breaking lines elsewhere
    /// (measured: one line is 575.4 pt wide in a 10,193-unit string and
    /// 588.6 pt in a 10,382-unit one). No typesetter here covers more than
    /// this, whole hard lines (BiDi paragraphs) at a time, so a line lays out
    /// the same however much text surrounds it, as a browser shapes and
    /// breaks each paragraph on its own.
    static let maxTypesetterLength = 8_192
    /// Hard lines longer than this (in UTF-16 code units) use a sliding
    /// `CTTypesetter` window to avoid Core Text / ICU's O(N^2) line-break scan
    /// from the start of each hard line.
    static let slidingWindowThreshold = 4_096
    static let slidingWindowSize = 2_048
    static let slidingWindowLookahead = 64

    static func layout(_ text: StyledText, width: CGFloat, options: Options) -> TextLayout {
        let length = text.length
        guard length > 0 else { return .empty }
        let nsString = text.string.mutableString
        var builder = Builder(text: text, nsString: nsString, options: options, availableWidth: width)
        layoutWindows(
            attributedString: text.string, nsString: nsString, length: length, paragraphs: text.paragraphs,
            width: width, wraps: options.wraps, forceContinuation: false, into: &builder)
        return builder.finish()
    }

    /// Incremental layout from an already-sliced suffix `StyledText` (avoiding
    /// allocating a full `NSMutableAttributedString` for the unchanged prefix).
    /// Returns `nil` when complex BiDi appears in the suffix and full layout is required.
    static func layoutSuffix(
        fullString: String,
        suffix: StyledText,
        width: CGFloat,
        options: Options,
        appendingTo previous: TextLayout,
        keepCount: Int
    ) -> TextLayout? {
        let suffixLength = suffix.length
        guard !previous.hasComplexBiDi, keepCount >= 2, keepCount < previous.lines.count, suffixLength > 0 else {
            return nil
        }
        let resumeLine = previous.lines[keepCount]
        let resumeUTF16 = resumeLine.range.lowerBound
        let suffixNS = suffix.string.mutableString
        let paragraph = suffix.paragraphs.first
        let lastKept = previous.lines[keepCount - 1]
        let keptRunEnd = resumeLine.runs.lowerBound
        let keptDecorationsEnd = resumeLine.decorations.lowerBound
        let keptY = lastKept.bottom

        var builder = Builder(
            text: suffix, nsString: suffixNS, options: options, availableWidth: width,
            initialLines: Array(previous.lines[..<keepCount]),
            initialRuns: Array(previous.runs[..<keptRunEnd]),
            initialDecorations: Array(previous.decorations[..<keptDecorationsEnd]),
            initialY: keptY,
            initialWidth: previous.lines[..<keepCount].reduce(CGFloat(0)) { max($0, $1.x + $1.width) },
            previousQuoteBars: paragraph?.quoteBars ?? [],
            utf16BaseOffset: resumeUTF16)

        layoutWindows(
            attributedString: suffix.string, nsString: suffixNS, length: suffixLength,
            paragraphs: paragraph.map { [$0] } ?? [], width: width, wraps: options.wraps, forceContinuation: true,
            into: &builder)
        if builder.hasComplexBiDi { return nil }
        return builder.finish(overrideString: fullString)
    }

    /// Whether `index` starts a cluster, as carets, hit tests and selection
    /// edges take them: Apple's composed character sequence there starts at
    /// `index` (asked per offset, as `NSTextView` does), or a line ends just
    /// before it. A cluster always ends at a line terminator (UAX #29 GB4),
    /// where Apple's runs on into a combining mark starting the next line,
    /// which a typesetter window starting there cannot see.
    static func startsCluster(_ string: NSString, at index: Int) -> Bool {
        index == 0 || endsLine(string.character(at: index - 1))
            || CFStringGetRangeOfComposedCharactersAtIndex(string, index).location == index
    }

    /// The cluster containing `index` (Apple's composed character sequence,
    /// clipped at line terminators so it agrees with `startsCluster`).
    static func clusterRange(in string: NSString, at index: Int) -> NSRange {
        guard index >= 0, index < string.length else { return NSRange(location: index, length: 0) }
        if endsLine(string.character(at: index)) { return NSRange(location: index, length: 1) }
        var range = string.rangeOfComposedCharacterSequence(at: index)
        while range.location < index, endsLine(string.character(at: range.location)) {
            range.location += 1
            range.length -= 1
        }
        return range
    }

    /// The smallest cluster-aligned range covering `range` (never crossing a
    /// line terminator before `range`).
    static func clusterRange(in string: NSString, for range: NSRange) -> NSRange {
        guard range.length > 0 else { return range }
        let start = clusterRange(in: string, at: range.location).location
        let end = NSMaxRange(clusterRange(in: string, at: NSMaxRange(range) - 1))
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Mandatory line breaks (UAX #14 BK, CR, LF, NL).
    static func endsLine(_ unit: unichar) -> Bool {
        switch unit {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: true
        default: false
        }
    }

    /// Letters ICU breaks lines between by dictionary (UAX #14 class SA):
    /// Thai, Lao, Myanmar, Khmer and the Tai scripts.
    private static func breaksByDictionary(_ unit: unichar) -> Bool {
        switch unit {
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x1950...0x19DF, 0x1A20...0x1AAF, 0xA9E0...0xA9FF,
            0xAA60...0xAADF:
            true
        default:
            false
        }
    }

    /// Conservative UTF-16 check covering Hebrew, Arabic, Syriac, Thaana, NKo,
    /// Samaritan, Mandaic, BiDi control marks, Arabic Presentation Forms, and
    /// astral RTL script high surrogates (U+10800..U+10FFF, U+1E800..U+1EFFF).
    static func isBiDiCodeUnit(_ u: unichar) -> Bool {
        if u <= 0x08FF { return true }
        if u >= 0x200E && u <= 0x200F { return true }
        if u >= 0x202A && u <= 0x202E { return true }
        if u >= 0x2066 && u <= 0x2069 { return true }
        if u >= 0xD802 && u <= 0xD803 { return true }
        if u >= 0xD83A && u <= 0xD83B { return true }
        if u >= 0xFB1D && u <= 0xFDFF { return true }
        if u >= 0xFE70 && u <= 0xFEFF { return true }
        return false
    }

    /// UAX #9 P2/P3 (`dir="auto"`): true when the paragraph starting at
    /// `start` has a strong right-to-left character before any strong
    /// left-to-right character. O(1) on normal LTR text (first ASCII letter
    /// returns `false`).
    static func paragraphIsRTL(_ string: NSString, startingAt start: Int) -> Bool {
        let length = string.length
        var index = max(0, start)
        while index < length {
            let unit = string.character(at: index)
            if endsLine(unit) { return false }
            if (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) { return false }
            if unit >= 0x0590 {
                if (unit <= 0x08FF && unit != 0x061C) || unit == 0x200F || (unit >= 0xFB1D && unit <= 0xFDFF)
                    || (unit >= 0xFE70 && unit <= 0xFEFC)
                {
                    return true
                }
                if unit == 0x200E { return false }
                if unit >= 0x0900, !isBiDiCodeUnit(unit) {
                    if let scalar = UnicodeScalar(unit), scalar.properties.isAlphabetic { return false }
                }
            } else if unit >= 0x00C0, let scalar = UnicodeScalar(unit), scalar.properties.isAlphabetic {
                return false
            }
            index += 1
        }
        return false
    }

    /// Leading x for a line (`dir="auto"` flush-right alignment for RTL
    /// paragraphs, matching browsers and `NSTextView`).
    static func lineOriginX(indent: CGFloat, lineWidth: CGFloat, availableWidth: CGFloat, isRTL: Bool) -> CGFloat {
        guard isRTL, availableWidth.isFinite else { return indent }
        return max(0, availableWidth - indent - lineWidth)
    }

    /// Lays `attributedString` out in typesetter windows of at most
    /// `maxTypesetterLength` whole hard lines; a left-to-right hard line
    /// longer than `slidingWindowThreshold` slides a 2 KB window along itself
    /// instead (right-to-left reordering spans its wrapped lines, so a BiDi
    /// hard line keeps one typesetter).
    private static func layoutWindows(
        attributedString: NSAttributedString,
        nsString: NSString,
        length: Int,
        paragraphs: [StyledParagraph],
        width: CGFloat,
        wraps: Bool,
        forceContinuation: Bool,
        into builder: inout Builder
    ) {
        var paragraphIndex = 0
        /// The paragraph a line starting at `start` belongs to, and whether
        /// it starts there.
        func paragraph(at start: Int) -> (StyledParagraph?, isStart: Bool) {
            guard !forceContinuation else { return (paragraphs.first, false) }
            while paragraphIndex + 1 < paragraphs.count, paragraphs[paragraphIndex + 1].start <= start {
                paragraphIndex += 1
            }
            let paragraph = paragraphs.isEmpty ? nil : paragraphs[paragraphIndex]
            return (paragraph, paragraph.map { $0.start == start } ?? (start == 0))
        }

        /// Lays out lines of `window` from `start` (window-relative; the text
        /// before it is context) until its end, or (for a window ending
        /// inside a hard line) until a line ends too near its end to be sure
        /// of; returns where it stopped and where its last line started
        /// (window-relative).
        func typeset(
            _ window: Range<Int>, from start: Int = 0, endsInsideHardLine: Bool
        ) -> (stop: Int, lastLineStart: Int) {
            let windowAttr =
                window.count == length
                ? attributedString : attributedString.attributedSubstring(from: NSRange(window))
            let windowNS = window.count == length ? nsString : windowAttr.string as NSString
            let typesetter = CTTypesetterCreateWithAttributedString(windowAttr)
            let windowLength = window.count
            var localStart = start
            var lastLineStart = start
            while localStart < windowLength {
                let (paragraph, isParagraphStart) = paragraph(at: window.lowerBound + localStart)
                let indent = (isParagraphStart ? paragraph?.firstLineIndent : paragraph?.headIndent) ?? 0
                let count = nextLineLength(
                    typesetter: typesetter, nsString: windowNS, start: localStart, length: windowLength,
                    availableWidth: max(1, width - indent), wraps: wraps)
                let localEnd = localStart + count
                if endsInsideHardLine, localEnd >= windowLength || windowLength - localEnd < slidingWindowLookahead {
                    break
                }
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: localStart, length: count))
                let lastUnit = windowNS.character(at: localEnd - 1)
                let endsWithBreak = wraps ? Self.endsLine(lastUnit) : lastUnit == 0x0A
                builder.add(
                    line, range: localStart..<localEnd, indent: indent, paragraph: paragraph,
                    isParagraphStart: isParagraphStart, endsWithNewline: endsWithBreak,
                    windowNSString: windowNS, windowOffset: window.lowerBound)
                lastLineStart = localStart
                localStart = localEnd
            }
            return (localStart, lastLineStart)
        }

        /// Slides a window along one long left-to-right hard line, cut at
        /// cluster boundaries, discarding each window's last line (it could
        /// break differently with the text after it); a window whose first
        /// line does not fit before its end doubles. A window cut beside a
        /// dictionary-broken letter (`breaksByDictionary`) starts with the
        /// line before the one it lays out: ICU segments a word from its
        /// start, so a window starting inside a word broke it elsewhere than
        /// one typesetter over the whole line (`slidingWindowRegressions`: a
        /// Lao word cut at 2 units instead of 17 at width 120). Other text
        /// breaks the same without it (the scale-50 fuzzers), and skipping it
        /// saves ~4% of a long paragraph's layout.
        func slide(_ hardLine: Range<Int>) {
            var contextStart = hardLine.lowerBound
            var resume = hardLine.lowerBound
            var windowCap = slidingWindowSize
            while resume < hardLine.upperBound {
                let rawEnd = min(hardLine.upperBound, resume + windowCap)
                let windowEnd =
                    rawEnd < hardLine.upperBound
                    ? min(hardLine.upperBound, NSMaxRange(nsString.rangeOfComposedCharacterSequence(at: rawEnd - 1)))
                    : hardLine.upperBound
                let laid = typeset(
                    contextStart..<windowEnd, from: resume - contextStart,
                    endsInsideHardLine: windowEnd < hardLine.upperBound)
                if contextStart + laid.stop == resume {
                    windowCap = min(hardLine.upperBound - resume, windowCap * 2)
                    continue
                }
                resume = contextStart + laid.stop
                let cutsWord =
                    resume < hardLine.upperBound
                    && (breaksByDictionary(nsString.character(at: resume - 1))
                        || breaksByDictionary(nsString.character(at: resume)))
                contextStart = cutsWord ? contextStart + laid.lastLineStart : resume
                windowCap = slidingWindowSize
            }
        }

        // Short texts (nearly every row) are one window without scanning.
        guard length > slidingWindowThreshold else {
            _ = typeset(0..<length, endsInsideHardLine: false)
            return
        }
        var buffer = [unichar](repeating: 0, count: 4_096)
        var bufferStart = 0
        var bufferEnd = 0
        var groupStart = 0
        var lineStart = 0
        while lineStart < length {
            // The hard line at `lineStart` (through its newline), and whether
            // it holds right-to-left text.
            var lineEnd = length
            var isBiDi = false
            var position = lineStart
            scan: while position < length {
                if position >= bufferEnd {
                    bufferStart = position
                    let count = min(buffer.count, length - bufferStart)
                    nsString.getCharacters(&buffer, range: NSRange(location: bufferStart, length: count))
                    bufferEnd = bufferStart + count
                }
                for index in (position - bufferStart)..<(bufferEnd - bufferStart) {
                    let unit = buffer[index]
                    if unit == 0x0A {
                        lineEnd = bufferStart + index + 1
                        break scan
                    }
                    if unit >= 0x0590, !isBiDi, isBiDiCodeUnit(unit) { isBiDi = true }
                }
                position = bufferEnd
            }
            let slides = wraps && !isBiDi && lineEnd - lineStart > slidingWindowThreshold
            if slides || lineEnd - groupStart > maxTypesetterLength {
                if lineStart > groupStart { _ = typeset(groupStart..<lineStart, endsInsideHardLine: false) }
                groupStart = lineStart
            }
            if slides {
                slide(lineStart..<lineEnd)
                groupStart = lineEnd
            }
            lineStart = lineEnd
        }
        if length > groupStart { _ = typeset(groupStart..<length, endsInsideHardLine: false) }
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
            let newline = nsString.range(of: "\n", options: .literal, range: NSRange(location: start, length: length - start))
            count = newline.location == NSNotFound ? length - start : NSMaxRange(newline) - start
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
            isParagraphStart: Bool, endsWithNewline: Bool,
            windowNSString: NSString? = nil, windowOffset: Int = 0
        ) {
            let activeString = windowNSString ?? nsString
            let baseOffset = utf16BaseOffset + windowOffset
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
            let paragraphStart = paragraph?.start ?? 0
            let isRTL =
                options.wraps && options.alignsRTLToWidth && availableWidth.isFinite
                && TextLayoutEngine.paragraphIsRTL(nsString, startingAt: paragraphStart)
            let lineX = TextLayoutEngine.lineOriginX(
                indent: indent, lineWidth: lineWidth, availableWidth: availableWidth, isRTL: isRTL)
            let firstRun = runs.count
            let firstDecoration = decorations.count
            let carets = addRunsAndCarets(
                of: line, range: range, indent: lineX, baseline: baseline, width: lineWidth,
                activeString: activeString, baseOffset: baseOffset)
            if let paragraph {
                addParagraphDecorations(
                    paragraph, lineHeight: height, gapAbove: gapAbove, isParagraphStart: isParagraphStart)
            }
            let textRange = (range.lowerBound + baseOffset)..<(range.upperBound + baseOffset)
            lines.append(
                TextLine(
                    top: y, baseline: baseline, height: height, x: lineX, width: lineWidth, range: textRange,
                    caretOffsets: carets, runs: firstRun..<runs.count,
                    decorations: firstDecoration..<decorations.count, endsWithNewline: endsWithNewline))
            width = max(width, lineX + lineWidth)
            y += height
        }

        func finish(overrideString: String? = nil) -> TextLayout {
            TextLayout(
                string: overrideString ?? text.string.string, size: CGSize(width: ceil(width), height: ceil(y)),
                lines: lines, runs: runs, decorations: decorations, links: text.links, hasComplexBiDi: hasComplexBiDi)
        }

        /// Copies the line's runs and their decorations, and returns its
        /// carets, in one pass over Core Text's own glyph buffers.
        private mutating func addRunsAndCarets(
            of line: CTLine, range: Range<Int>, indent: CGFloat, baseline: CGFloat, width: CGFloat,
            activeString: NSString, baseOffset: Int
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
                            rangeStart: rangeStart, nsString: activeString, indent: indent, into: &carets)
                    }
                    return positions.map { CGPoint(x: indent + $0.x, y: $0.y - baseline) }
                }

                let runIsRTL = needsCoreTextCarets && CTRunGetStatus(run).contains(.rightToLeft)
                let runVisualWidth: CGFloat =
                    needsCoreTextCarets
                    ? CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil)) : 0
                runs.append(
                    TextGlyphRun(
                        font: font, glyphs: glyphs, positions: positions, color: style.color,
                        range: (stringRange.location + baseOffset)..<(
                            stringRange.location + baseOffset + stringRange.length),
                        linkIndex: style.linkIndex, isRightToLeft: runIsRTL, visualWidth: runVisualWidth))
                addRunDecorations(run, style: style, font: font, start: positions[0].x, baseline: baseline)
            }

            if needsCoreTextCarets {
                return TextLayoutEngine.enumeratedCaretOffsets(
                    of: line, range: range, string: activeString, indent: indent, width: width)
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

        /// The carets of `run`'s characters (see `caretOffsets`), into
        /// `offsets` indexed from `rangeStart`.
        static func accumulateRunCarets(
            run: CTRun, count: Int, positions: UnsafeBufferPointer<CGPoint>, stringRange: CFRange,
            rangeStart: Int, nsString: NSString, indent: CGFloat, into offsets: inout [CGFloat]
        ) {
            // The run's text, read once: a message per glyph was a third of a
            // long code line's layout.
            withUnsafeTemporaryAllocation(of: unichar.self, capacity: max(1, stringRange.length)) { units in
                guard let unitBase = units.baseAddress else { return }
                CFStringGetCharacters(nsString, stringRange, unitBase)
                withRunStringIndices(run, count: count) { indicesPtr in
                    let runEnd = stringRange.location + stringRange.length
                    var glyph = 0
                    while glyph < count {
                        let first = indicesPtr[glyph]
                        // A character drawn as several glyphs carets at its first.
                        var nextGlyph = glyph + 1
                        while nextGlyph < count, indicesPtr[nextGlyph] == first { nextGlyph += 1 }
                        let end = nextGlyph < count ? indicesPtr[nextGlyph] : runEnd
                        // Carets only at grapheme cluster boundaries, as in
                        // Blink: Core Text can give a character inside a
                        // cluster a glyph of its own (a VS16 after a fallback
                        // font drew its base, an Indic spacing mark), which
                        // would put a caret inside the cluster.
                        let startsCluster =
                            alwaysStartsCluster(units[first - stringRange.location])
                            || TextLayoutEngine.startsCluster(nsString, at: first)
                        if end > first, startsCluster {
                            let span = end - first
                            var isLigature = false
                            if span > 1 {
                                isLigature = true
                                for idx in first..<end {
                                    let unit = units[idx - stringRange.location]
                                    if unit >= 0x80 || unit == 0x0D || unit == 0x0A {
                                        isLigature = false
                                        break
                                    }
                                }
                            }
                            let width: CGFloat
                            if isLigature {
                                var advance = CGSize.zero
                                CTRunGetAdvances(run, CFRange(location: glyph, length: 1), &advance)
                                width = advance.width
                            } else {
                                width = 0
                            }
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
        }

        /// Code units that always start a grapheme cluster (UAX #29: none is
        /// Extend, SpacingMark, ZWJ, Prepend, a surrogate or a Hangul jamo):
        /// Latin, Greek and Cyrillic letters, kana and CJK ideographs. Not ©
        /// and ®, emoji that join a ZWJ sequence (GB11). Others ask Core Text.
        @inline(__always)
        static func alwaysStartsCluster(_ unit: unichar) -> Bool {
            (unit < 0x0300 && unit != 0xA9 && unit != 0xAE) || (0x0370...0x0482).contains(unit)
                || (0x3041...0x3096).contains(unit) || (0x30A1...0x30FA).contains(unit)
                || (0x4E00...0x9FFF).contains(unit)
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
                            x: start - 3, y: baseline - ascent - 1, width: runWidth + 6, height: ascent + descent + 2)))
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
            _ paragraph: StyledParagraph, lineHeight: CGFloat, gapAbove: CGFloat, isParagraphStart: Bool
        ) {
            for bar in paragraph.quoteBars {
                let joinsAbove = previousQuoteBars.contains(bar)
                decorations.append(
                    TextDecoration(
                        kind: .quoteBar,
                        rect: CGRect(
                            x: bar, y: y - (joinsAbove ? gapAbove : 0), width: options.quoteBarWidth,
                            height: lineHeight + (joinsAbove ? gapAbove : 0))))
            }
            previousQuoteBars = paragraph.quoteBars
            if isParagraphStart, let task = paragraph.taskMarker {
                let boxSize = min(14, max(11, (lineHeight * 0.68).rounded()))
                let boxY = y + ((lineHeight - boxSize) / 2).rounded()
                decorations.append(
                    TextDecoration(
                        kind: task.checked ? .taskChecked : .taskUnchecked,
                        rect: CGRect(x: task.x, y: boxY, width: boxSize, height: boxSize)))
            }
            if paragraph.isRule {
                decorations.append(
                    TextDecoration(
                        kind: .rule,
                        rect: CGRect(
                            x: paragraph.firstLineIndent, y: (y + lineHeight / 2).rounded(.down),
                            width: max(0, availableWidth - paragraph.firstLineIndent), height: 1)))
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
    /// every character in visual order; with `string`, edges inside a cluster
    /// are dropped so only cluster boundaries get carets (Core Text breaks
    /// Myanmar and Devanagari syllables finer than composed character
    /// sequences, and a mid-cluster trailing edge would otherwise pin the
    /// cluster's end caret short of its visual edge).
    static func enumeratedCaretOffsets(
        of line: CTLine, range: Range<Int>, string: NSString? = nil, indent: CGFloat, width: CGFloat
    ) -> [CGFloat] {
        var offsets = [CGFloat](repeating: .nan, count: range.count + 1)
        let start = range.lowerBound
        CTLineEnumerateCaretOffsets(line) { offset, index, leadingEdge, _ in
            let position: Int
            if leadingEdge {
                if let string, !startsCluster(string, at: index) { return }
                position = index - start
            } else {
                let next = index + 1
                if let string, next < string.length, !startsCluster(string, at: next) { return }
                position = next - start
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
