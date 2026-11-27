import CoreGraphics
import CoreText
import Dispatch
import Foundation

/// One break segment inside a prepared paragraph (`REDESIGN.md §4`).
/// Non-primary segments represent internal space runs inside a single UAX #14
/// token so the arithmetic fit reproduces Core Text's space-overflow shortcut
/// with 0 break differences against `CTTypesetterSuggestLineBreak`.
nonisolated struct PreparedSegment: Equatable, Sendable {
    /// UTF-16 end offset relative to the paragraph's start.
    var end: UInt32
    /// Total width including trailing whitespace.
    var totalWidth: Float
    /// Visible width excluding trailing whitespace and newline.
    var visibleWidth: Float
    /// Bit-packed: lower 13 bits = metrics index (`0` = `.zero` / glyphless,
    /// `1` = paragraph default, `2...` = `extraMetrics[index - 2]`),
    /// bit 13 = `isPrimaryOpp`, bit 14 = `isHardBreak`, bit 15 = `hasTrailingSpace`.
    var metricsAndFlags: UInt16

    @inline(__always) var metricsIndex: Int { Int(metricsAndFlags & 0x1FFF) }
    @inline(__always) var isPrimaryOpp: Bool { (metricsAndFlags & 0x2000) != 0 }
    @inline(__always) var isHardBreak: Bool { (metricsAndFlags & 0x4000) != 0 }
    @inline(__always) var hasTrailingSpace: Bool { (metricsAndFlags & 0x8000) != 0 }
}

/// Width-independent prepared text (`REDESIGN.md §4`): built once off the main
/// thread from `StyledText` (or code), kept across width changes so resizing
/// re-runs only the arithmetic fit (`fit(width:)`).
nonisolated final class PreparedText: Sendable {
    /// Unwrapped code line metadata (one per source line when `wraps == false`).
    struct CodeLine: Equatable, Sendable {
        var byteRange: Range<Int>  // excluding trailing \r/\n
        var utf16Range: Range<Int>  // including trailing \r/\n
        var width: CGFloat
        var isPureASCII: Bool
        var hasTabs: Bool
        var endsWithNewline: Bool
    }

    struct Paragraph: Sendable {
        let styled: StyledParagraph
        let range: Range<Int>  // UTF-16 range in `PreparedText.text`
        let runSlice: Range<Int>  // indices in `PreparedText.runs` overlapping `range`
        let isRTL: Bool
        let defaultMetrics: LineFontMetrics
        let extraMetrics: [LineFontMetrics]
        let segments: [PreparedSegment]
        let usedInContext: Bool
        let isPureASCII: Bool
        /// Retained only for paragraphs that needed in-context shaping so
        /// emergency mid-word breaks stay pure arithmetic without re-shaping.
        let inContextUnitWidths: [Float]?
        let inContextUnitMetrics: [LineFontMetrics]?
        let hasInlineDecorations: Bool
        /// True when any character in this paragraph might require Core Text
        /// carets (RTL / non-monotonic shaping).
        let hasBiDiUnits: Bool
        /// True when the paragraph contains `\t` (`0x09`) so `fit(width:)`
        /// computes dynamic tab stops relative to the wrapped line's x origin.
        let hasTabUnits: Bool
    }

    static let parallelTokenizerThreshold = 32_768

    let text: String
    let length: Int
    let runs: [StyledRun]
    let links: [URL]
    let options: TextLayoutEngine.Options
    let paragraphs: [Paragraph]
    /// Populated for unwrapped code blocks (`wraps == false`), sharing the same
    /// `FontWidthTable` as prose while keeping O(visible columns) tiling and
    /// O(log lines) `memcmp` streaming diffs.
    let codeLines: [CodeLine]?
    let codeFontTable: FontWidthTable?
    let codeTabInterval: CGFloat
    let hasParagraphDecorations: Bool
    let hasComplexBiDi: Bool
    let retainedBytes: Int

    static let empty = PreparedText(emptyWith: .init(lineSpacing: 0))

    private init(emptyWith options: TextLayoutEngine.Options) {
        self.text = ""
        self.length = 0
        self.runs = []
        self.links = []
        self.options = options
        self.paragraphs = []
        self.codeLines = nil
        self.codeFontTable = nil
        self.codeTabInterval = 0
        self.hasParagraphDecorations = false
        self.hasComplexBiDi = false
        self.retainedBytes = 64
    }

    /// Prepares `styled` text for wrapping (`options.wraps == true`) or
    /// unwrapped layout (`options.wraps == false`), reusing unchanged prefix
    /// paragraphs/segments from `previous` when streaming.
    init(_ styled: StyledText, options: TextLayoutEngine.Options, previous: PreparedText? = nil) {
        self.text = styled.text
        self.length = styled.length
        self.runs = styled.runs
        self.links = styled.links
        self.options = options

        guard styled.length > 0 else {
            self.paragraphs = []
            self.codeLines = nil
            self.codeFontTable = nil
            self.codeTabInterval = 0
            self.hasParagraphDecorations = false
            self.hasComplexBiDi = false
            self.retainedBytes = 64
            return
        }

        let ns = styled.text as NSString
        let cf = ns as CFString
        var reusableTokenizer: CFStringTokenizer?
        var fontTableCache: [(font: CTFont, table: FontWidthTable)] = []
        var bmpClusterCaches: [[UInt16: (width: Float, metrics: LineFontMetrics)]] = []
        var bmpPairKernCaches: [[UInt32: Float]] = []
        let styledParagraphs =
            styled.paragraphs.isEmpty
            ? [StyledParagraph(start: 0, firstLineIndent: 0, headIndent: 0, spacingBefore: 0, quoteBars: [])]
            : styled.paragraphs

        var builtParagraphs: [Paragraph] = []
        builtParagraphs.reserveCapacity(styledParagraphs.count)
        var anyParaDec = false
        var anyBiDi = false
        var bytes = 128 + styled.runs.count * 48

        let canReuseFromPrevious =
            previous.map {
                $0.options.wraps == options.wraps
                    && $0.options.fixedLineHeight == options.fixedLineHeight
                    && $0.options.alignsRTLToWidth == options.alignsRTLToWidth
                    && $0.codeLines == nil
            } ?? false

        var runCursor = 0
        for pIdx in 0..<styledParagraphs.count {
            let sp = styledParagraphs[pIdx]
            let pStart = sp.start
            let pEnd = pIdx + 1 < styledParagraphs.count ? styledParagraphs[pIdx + 1].start : styled.length
            guard pEnd > pStart else { continue }
            let pRange = pStart..<pEnd

            while runCursor < styled.runs.count, styled.runs[runCursor].range.upperBound <= pStart {
                runCursor += 1
            }
            var runEnd = runCursor
            while runEnd < styled.runs.count, styled.runs[runEnd].range.lowerBound < pEnd {
                runEnd += 1
            }
            let runSlice = runCursor..<runEnd

            if !sp.quoteBars.isEmpty || sp.isRule || sp.taskMarker != nil {
                anyParaDec = true
            }

            // Streaming fast path: reuse unchanged prefix paragraph in O(1).
            if canReuseFromPrevious, let prev = previous, pIdx < prev.paragraphs.count {
                let prevP = prev.paragraphs[pIdx]
                if prevP.range == pRange,
                    Self.sameStyledParagraph(prevP.styled, sp),
                    Self.sameRuns(prev.runs, prevP.runSlice, styled.runs, runSlice),
                    Self.sameTextSlice(prev.text, styled.text, utf16Range: pRange)
                {
                    builtParagraphs.append(prevP)
                    if prevP.hasBiDiUnits { anyBiDi = true }
                    bytes += Self.paragraphBytes(prevP)
                    continue
                }
            }

            // Check for incremental single-paragraph tail extension when streaming a giant paragraph
            // (both plain and multi-run pure-ASCII styled paragraphs).
            let prevForTail: (prevText: String, prevRuns: [StyledRun], para: Paragraph)?
            if canReuseFromPrevious, let prev = previous, pIdx < prev.paragraphs.count,
                pRange.count > 2_048
            {
                let prevP = prev.paragraphs[pIdx]
                if prevP.range.lowerBound == pRange.lowerBound,
                    prevP.range.upperBound < pRange.upperBound,
                    !prevP.usedInContext,
                    prevP.isPureASCII,
                    !prevP.hasTabUnits,
                    !prevP.runSlice.isEmpty,
                    !runSlice.isEmpty,
                    CFEqual(prev.runs[prevP.runSlice.lowerBound].font.font, styled.runs[runSlice.lowerBound].font.font),
                    Self.sameStyledParagraph(prevP.styled, sp)
                {
                    prevForTail = (prev.text, prev.runs, prevP)
                } else {
                    prevForTail = nil
                }
            } else {
                prevForTail = nil
            }

            let para = Self.prepareParagraph(
                styled: sp,
                range: pRange,
                runSlice: runSlice,
                allRuns: styled.runs,
                fullText: styled.text,
                nsString: ns,
                cfString: cf,
                options: options,
                previousTail: prevForTail,
                reusableTokenizer: &reusableTokenizer,
                fontTableCache: &fontTableCache,
                bmpClusterCaches: &bmpClusterCaches,
                bmpPairKernCaches: &bmpPairKernCaches)
            if para.hasBiDiUnits { anyBiDi = true }
            bytes += Self.paragraphBytes(para)
            builtParagraphs.append(para)
        }

        self.paragraphs = builtParagraphs
        self.codeLines = nil
        self.codeFontTable = nil
        self.codeTabInterval = 0
        self.hasParagraphDecorations = anyParaDec
        self.hasComplexBiDi = anyBiDi
        self.retainedBytes = bytes
    }

    /// Unified code path: uses `FontWidthTable` with wrapping off and 4-column
    /// tab stops (`style.codeTabInterval`) for exact widths on every line
    /// (ASCII, box-drawing, CJK, emoji, and RTL).
    init(code: String, colors: CodeColors?, style: TextStyle) {
        let codeFont = style.font(.code)
        let table = FontWidthTable.table(for: codeFont)
        let tabInterval = style.codeTabInterval
        let options = TextLayoutEngine.Options(lineSpacing: 0, wraps: false, fixedLineHeight: style.codeLineHeight)

        var runs: [StyledRun] = []
        if let colorRuns = colors?.runs, !colorRuns.isEmpty {
            let total = code.utf16.count
            var cursor = 0
            for run in colorRuns where run.range.lowerBound >= cursor && run.range.upperBound <= total {
                if run.range.lowerBound > cursor {
                    runs.append(
                        StyledRun(
                            range: cursor..<run.range.lowerBound, font: codeFont, style: TextRunStyle(),
                            tabInterval: tabInterval))
                }
                if run.range.upperBound > run.range.lowerBound {
                    runs.append(
                        StyledRun(
                            range: run.range, font: codeFont, style: TextRunStyle(color: run.color),
                            tabInterval: tabInterval))
                }
                cursor = run.range.upperBound
            }
            if cursor < total {
                runs.append(
                    StyledRun(range: cursor..<total, font: codeFont, style: TextRunStyle(), tabInterval: tabInterval))
            }
        } else if !code.isEmpty {
            runs.append(
                StyledRun(
                    range: 0..<code.utf16.count, font: codeFont, style: TextRunStyle(), tabInterval: tabInterval))
        }

        self.text = code
        self.runs = runs
        self.links = []
        self.options = options
        self.codeFontTable = table
        self.codeTabInterval = tabInterval
        self.hasParagraphDecorations = false

        guard !code.isEmpty else {
            self.length = 0
            self.paragraphs = []
            self.codeLines = []
            self.hasComplexBiDi = false
            self.retainedBytes = 64
            return
        }

        var lines: [CodeLine] = []
        var totalUTF16 = 0
        var anyBiDi = false
        let asciiWidths = table.asciiWidths
        let fallbackAdv = max(1, CGFloat(asciiWidths[0x30]))

        func scanBytes<C: RandomAccessCollection>(_ bytes: C) where C.Element == UInt8, C.Index == Int {
            let count = bytes.count
            lines.reserveCapacity(max(8, count / 40))
            var idx = 0
            var lineByteStart = 0
            var lineUTF16Start = 0
            var colX: CGFloat = 0
            var visibleX: CGFloat = 0
            var lineIsPureASCII = true
            var lineHasTabs = false
            var lineNeedsInContext = false

            func finishLine(contentEndByte: Int, lineEndUTF16: Int, endsWithNewline: Bool) {
                let width: CGFloat
                if lineIsPureASCII {
                    width = visibleX
                } else {
                    let measured = Self.measureNonASCIICodeLine(
                        code: code, byteRange: lineByteStart..<contentEndByte, table: table,
                        tabInterval: tabInterval, needsInContext: lineNeedsInContext)
                    width = measured.width
                    if measured.hasBiDi { anyBiDi = true }
                }
                lines.append(
                    CodeLine(
                        byteRange: lineByteStart..<contentEndByte,
                        utf16Range: lineUTF16Start..<lineEndUTF16,
                        width: width,
                        isPureASCII: lineIsPureASCII,
                        hasTabs: lineHasTabs,
                        endsWithNewline: endsWithNewline))
            }

            while idx < count {
                let b = bytes[idx]
                if b == 0x0A {
                    let contentEnd = (idx > lineByteStart && bytes[idx - 1] == 0x0D) ? idx - 1 : idx
                    totalUTF16 += 1
                    finishLine(contentEndByte: contentEnd, lineEndUTF16: totalUTF16, endsWithNewline: true)
                    idx += 1
                    lineByteStart = idx
                    lineUTF16Start = totalUTF16
                    colX = 0
                    visibleX = 0
                    lineIsPureASCII = true
                    lineHasTabs = false
                    lineNeedsInContext = false
                } else if b == 0x0D, idx + 1 < count, bytes[idx + 1] == 0x0A {
                    totalUTF16 += 1
                    idx += 1
                } else if b < 0x80 {
                    if b == 0x09 {
                        lineHasTabs = true
                        colX = FontWidthTable.nextTabX(after: colX, tabInterval: tabInterval, fallbackAdvance: fallbackAdv)
                    } else if b >= 0x20 && b <= 0x7E {
                        colX += CGFloat(asciiWidths[Int(b)])
                        if b != 0x20 { visibleX = colX }
                    } else {
                        lineIsPureASCII = false
                        lineNeedsInContext = true
                    }
                    totalUTF16 += 1
                    idx += 1
                } else {
                    lineIsPureASCII = false
                    let charLen: Int
                    let utf16Len: Int
                    let scalar: UInt32
                    if b < 0xE0, idx + 1 < count {
                        charLen = 2
                        utf16Len = 1
                        scalar = (UInt32(b & 0x1F) << 6) | UInt32(bytes[idx + 1] & 0x3F)
                    } else if b < 0xF0, idx + 2 < count {
                        charLen = 3
                        utf16Len = 1
                        scalar =
                            (UInt32(b & 0x0F) << 12) | (UInt32(bytes[idx + 1] & 0x3F) << 6)
                            | UInt32(bytes[idx + 2] & 0x3F)
                    } else if idx + 3 < count {
                        charLen = 4
                        utf16Len = 2
                        scalar =
                            (UInt32(b & 0x07) << 18) | (UInt32(bytes[idx + 1] & 0x3F) << 12)
                            | (UInt32(bytes[idx + 2] & 0x3F) << 6) | UInt32(bytes[idx + 3] & 0x3F)
                    } else {
                        charLen = 1
                        utf16Len = 1
                        scalar = UInt32(b)
                    }
                    if FontWidthTable.scalarNeedsInContextShaping(scalar) {
                        lineNeedsInContext = true
                    }
                    totalUTF16 += utf16Len
                    idx = min(count, idx + charLen)
                }
            }
            if lineByteStart < count {
                finishLine(contentEndByte: count, lineEndUTF16: totalUTF16, endsWithNewline: false)
            }
        }

        if code.utf8.withContiguousStorageIfAvailable({ scanBytes($0); return true }) == nil {
            scanBytes(Array(code.utf8))
        }

        self.length = totalUTF16
        self.paragraphs = [
            Paragraph(
                styled: StyledParagraph(start: 0, firstLineIndent: 0, headIndent: 0, spacingBefore: 0, quoteBars: []),
                range: 0..<totalUTF16, runSlice: runs.indices, isRTL: false,
                defaultMetrics: table.baseMetrics, extraMetrics: [], segments: [],
                usedInContext: false, isPureASCII: !lines.contains(where: { !$0.isPureASCII }),
                inContextUnitWidths: nil, inContextUnitMetrics: nil,
                hasInlineDecorations: false, hasBiDiUnits: anyBiDi, hasTabUnits: false)
        ]
        self.codeLines = lines
        self.hasComplexBiDi = anyBiDi
        self.retainedBytes = 128 + lines.count * MemoryLayout<CodeLine>.stride + runs.count * 48
    }

    // MARK: - Arithmetic Fit (`REDESIGN.md §4.2`)

    /// Pure arithmetic line fit at `width` (ZERO Core Text calls).
    /// Produces exact line ranges, x/y coordinates, line heights, and size.
    func fit(width: CGFloat) -> TextLayout {
        guard length > 0 else { return .empty }

        // Fast unwrapped code path: O(lines) arithmetic, zero wrapping.
        if let codeLines {
            let lineHeight = options.fixedLineHeight ?? (codeFontTable?.baseMetrics.lineHeight ?? 16)
            let metrics = codeFontTable?.baseMetrics ?? LineFontMetrics(ascent: 12, descent: 3, leading: 0)
            let baselineShift = (lineHeight - CGFloat(metrics.ascent) - CGFloat(metrics.descent)) / 2 + CGFloat(metrics.ascent)
            let hasSyntaxColors = runs.count > 1 || (runs.first?.style.color != .primary)
            var outLines: [TextLine] = []
            outLines.reserveCapacity(codeLines.count)
            var maxW: CGFloat = 0
            for (idx, cl) in codeLines.enumerated() {
                let top = CGFloat(idx) * lineHeight
                if cl.width > maxW { maxW = cl.width }
                let fastBytes: Range<Int>? =
                    (cl.isPureASCII && !hasSyntaxColors && (codeFontTable?.uniformASCIIAdvance ?? 0) > 0)
                    ? cl.byteRange : nil
                outLines.append(
                    TextLine(
                        top: top,
                        baseline: top + baselineShift,
                        height: lineHeight,
                        x: 0,
                        width: cl.width,
                        range: cl.utf16Range,
                        paragraphIndex: 0,
                        gapAbove: 0,
                        isParagraphStart: idx == 0,
                        endsWithNewline: cl.endsWithNewline,
                        hasInlineDecorations: false,
                        fastASCIIByteRange: fastBytes,
                        hasTabs: cl.hasTabs))
            }
            let totalH = CGFloat(max(1, codeLines.count)) * lineHeight
            return TextLayout(
                prepared: self,
                availableWidth: width,
                size: CGSize(width: ceil(maxW), height: ceil(totalH)),
                lines: outLines,
                hasComplexBiDi: hasComplexBiDi)
        }

        // General wrapped (or unwrapped non-code) path.
        var outLines: [TextLine] = []
        outLines.reserveCapacity(max(8, paragraphs.count * 2))
        var y: CGFloat = 0
        var maxWidth: CGFloat = 0
        let ns = text as NSString
        let wraps = options.wraps
        let lineSpacing = options.lineSpacing
        let fixedLineHeight = options.fixedLineHeight
        let alignsRTL = wraps && options.alignsRTLToWidth && width.isFinite

        for (pIdx, para) in paragraphs.enumerated() {
            let pStart = para.range.lowerBound
            let pLen = para.range.count
            guard pLen > 0 else { continue }
            let isRTL = alignsRTL && para.isRTL
            let segs = para.segments
            let segCount = segs.count
            guard segCount > 0 else { continue }

            let defM = para.defaultMetrics
            var segIdx = 0
            var lineStart = 0  // paragraph-relative UTF-16 offset
            var isFirstLineOfPara = true
            var partialActive = false
            var curBidiIsRTL =
                para.hasBiDiUnits ? TextLayoutEngine.bidiParagraphIsRTL(ns, startingAt: pStart) : false

            // Lazy UTF-16 buffer only fetched if an emergency break, tabs, or
            // BiDi paragraph separator check occurs inside this paragraph.
            var paraUnits: [UInt16]?
            func unitsBuffer() -> [UInt16] {
                if let existing = paraUnits { return existing }
                var buf = [UInt16](repeating: 0, count: pLen)
                ns.getCharacters(&buf, range: NSRange(location: pStart, length: pLen))
                paraUnits = buf
                return buf
            }

            func emitLine(localStart: Int, localEnd: Int, visibleWidth: CGFloat, metrics: LineFontMetrics, isHardBreak: Bool) {
                let indent = isFirstLineOfPara ? para.styled.firstLineIndent : para.styled.headIndent
                let gapAbove: CGFloat =
                    outLines.isEmpty
                    ? 0
                    : (lineSpacing + (isFirstLineOfPara ? para.styled.spacingBefore : 0))
                y += gapAbove
                let m = metrics.isZero ? defM : metrics
                let lineH = fixedLineHeight ?? m.lineHeight
                let asc = CGFloat(m.ascent)
                let desc = CGFloat(m.descent)
                let baseline = y + (fixedLineHeight.map { ($0 - asc - desc) / 2 } ?? 0) + asc
                let visW = max(0, visibleWidth)
                let lineX = TextLayoutEngine.lineOriginX(
                    indent: indent, lineWidth: visW, availableWidth: width, isRTL: isRTL)
                let globalRange = (pStart + localStart)..<(pStart + localEnd)
                let hasInlDec = para.hasInlineDecorations
                let lineBidiRTL = curBidiIsRTL
                outLines.append(
                    TextLine(
                        top: y,
                        baseline: baseline,
                        height: lineH,
                        x: lineX,
                        width: visW,
                        range: globalRange,
                        paragraphIndex: pIdx,
                        gapAbove: gapAbove,
                        isParagraphStart: isFirstLineOfPara,
                        endsWithNewline: isHardBreak,
                        hasInlineDecorations: hasInlDec,
                        bidiIsRTL: lineBidiRTL))
                maxWidth = max(maxWidth, lineX + visW)
                y += lineH
                isFirstLineOfPara = false
                if isHardBreak && para.hasBiDiUnits && localEnd < pLen && localEnd > localStart {
                    let uBuf = unitsBuffer()
                    if TextLayoutEngine.isBiDiParagraphSeparator(uBuf[localEnd - 1]) {
                        curBidiIsRTL = TextLayoutEngine.bidiParagraphIsRTL(ns, startingAt: pStart + localEnd)
                    }
                }
            }

            @inline(__always)
            func segMetrics(_ seg: PreparedSegment) -> LineFontMetrics {
                let idx = seg.metricsIndex
                if idx == 0 { return .zero }
                if idx == 1 { return defM }
                return para.extraMetrics[idx - 2]
            }

            let hasTabUnits = para.hasTabUnits
            let tabUnits: [UInt16] = hasTabUnits ? unitsBuffer() : []

            segs.withUnsafeBufferPointer { sBuf in
                while segIdx < segCount {
                    let indent = isFirstLineOfPara ? para.styled.firstLineIndent : para.styled.headIndent
                    let availW = wraps ? Double(max(1, width - indent)) : Double.greatestFiniteMagnitude
                    var k = segIdx
                    var lineW: Double = 0
                    var lineVisW: Double = 0
                    var lastPrimarySeg = -1
                    var lastPrimaryVisW: Double = 0
                    var lastPrimaryMetrics = LineFontMetrics.zero
                    var curMetrics = LineFontMetrics.zero
                    var broke = false

                    if partialActive {
                        if para.hasBiDiUnits {
                            let em = Self.ctBiDiLineBreak(
                                para: para, from: lineStart, maxWidth: availW, bidiIsRTL: curBidiIsRTL,
                                units: unitsBuffer(), ns: ns, allRuns: runs)
                            emitLine(
                                localStart: lineStart, localEnd: em.end, visibleWidth: CGFloat(em.visW),
                                metrics: em.metrics, isHardBreak: em.hitHardBreak)
                            lineStart = em.end
                            while segIdx < segCount && Int(sBuf[segIdx].end) <= em.end { segIdx += 1 }
                            partialActive = segIdx < segCount && lineStart < Int(sBuf[segIdx].end)
                            continue
                        }
                        let seg = sBuf[segIdx]
                        let segEnd = Int(seg.end)
                        let res = Self.fitPartialSegment(
                            para: para, from: lineStart, to: segEnd, maxWidth: availW,
                            isHardBreak: seg.isHardBreak, hasTrailingSpace: seg.hasTrailingSpace,
                            units: unitsBuffer(), ns: ns, allRuns: runs)
                        partialActive = false
                        switch res {
                        case .fits(let tot, let vis, let m):
                            if seg.isHardBreak {
                                emitLine(
                                    localStart: lineStart, localEnd: segEnd, visibleWidth: CGFloat(vis),
                                    metrics: m, isHardBreak: true)
                                lineStart = segEnd
                                segIdx += 1
                                continue
                            }
                            curMetrics = m
                            if vis > 0 { lineVisW = vis }
                            if seg.isPrimaryOpp {
                                lastPrimarySeg = segIdx
                                lastPrimaryVisW = lineVisW
                                lastPrimaryMetrics = curMetrics
                            }
                            lineW = tot
                            k = segIdx + 1
                        case .trailingSpaceBreak(let vis, let m):
                            var endSeg = segIdx
                            var finalMetrics = m
                            if !seg.isHardBreak {
                                while endSeg + 1 < segCount && !sBuf[endSeg + 1].isHardBreak
                                    && sBuf[endSeg + 1].hasTrailingSpace && sBuf[endSeg + 1].visibleWidth == 0
                                {
                                    endSeg += 1
                                    finalMetrics.formMax(segMetrics(sBuf[endSeg]))
                                }
                            }
                            let endOff = Int(sBuf[endSeg].end)
                            emitLine(
                                localStart: lineStart, localEnd: endOff, visibleWidth: CGFloat(vis),
                                metrics: finalMetrics, isHardBreak: seg.isHardBreak)
                            lineStart = endOff
                            segIdx = endSeg + 1
                            continue
                        case .emergencyBreak(let end, let visW, let m, let hitHard):
                            emitLine(
                                localStart: lineStart, localEnd: end, visibleWidth: CGFloat(visW),
                                metrics: m, isHardBreak: hitHard)
                            lineStart = end
                            if end >= segEnd { segIdx += 1 } else { partialActive = true }
                            continue
                        }
                    }

                    while k < segCount {
                        let seg = sBuf[k]
                        let sm = segMetrics(seg)
                        let segTot: Double
                        let segVis: Double
                        if hasTabUnits {
                            let segStart = k == 0 ? 0 : Int(sBuf[k - 1].end)
                            let m = Self.measureSegmentWithTabs(
                                para: para, from: segStart, to: Int(seg.end), startX: lineW,
                                units: tabUnits, allRuns: runs)
                            segTot = m.tot
                            segVis = m.vis
                        } else {
                            segTot = Double(seg.totalWidth)
                            segVis = Double(seg.visibleWidth)
                        }

                        let candVisW = segVis > 0 ? (lineW + segVis) : lineVisW

                        if seg.isHardBreak {
                            if candVisW <= availW || segVis == 0 {
                                curMetrics.formMax(sm)
                                emitLine(
                                    localStart: lineStart, localEnd: Int(seg.end),
                                    visibleWidth: CGFloat(candVisW),
                                    metrics: curMetrics, isHardBreak: true)
                                lineStart = Int(seg.end)
                                segIdx = k + 1
                                broke = true
                                break
                            }
                        }

                        let nextTotal = lineW + segTot
                        if nextTotal <= availW {
                            curMetrics.formMax(sm)
                            lineVisW = candVisW
                            if seg.isPrimaryOpp {
                                lastPrimarySeg = k
                                lastPrimaryVisW = lineVisW
                                lastPrimaryMetrics = curMetrics
                            }
                            lineW = nextTotal
                            k += 1
                            continue
                        }

                        // CoreText space shortcut: overflow landed inside trailing whitespace of segment k.
                        if seg.hasTrailingSpace && (candVisW <= availW) {
                            curMetrics.formMax(sm)
                            var endSeg = k
                            while endSeg + 1 < segCount && !sBuf[endSeg + 1].isHardBreak
                                && sBuf[endSeg + 1].hasTrailingSpace && sBuf[endSeg + 1].visibleWidth == 0
                            {
                                endSeg += 1
                                curMetrics.formMax(segMetrics(sBuf[endSeg]))
                            }
                            let endOff = Int(sBuf[endSeg].end)
                            emitLine(
                                localStart: lineStart, localEnd: endOff,
                                visibleWidth: CGFloat(candVisW),
                                metrics: curMetrics, isHardBreak: false)
                            lineStart = endOff
                            segIdx = endSeg + 1
                            broke = true
                            break
                        }

                        if lastPrimarySeg >= segIdx {
                            let endOff = Int(sBuf[lastPrimarySeg].end)
                            emitLine(
                                localStart: lineStart, localEnd: endOff,
                                visibleWidth: CGFloat(lastPrimaryVisW),
                                metrics: lastPrimaryMetrics, isHardBreak: false)
                            lineStart = endOff
                            segIdx = lastPrimarySeg + 1
                            broke = true
                            break
                        }

                        // Emergency break: unspaced token wider than `availW`.
                        // For BiDi/Arabic paragraphs, ask Core Text on a bounded
                        // context-preserving window so mid-word Arabic shaping &
                        // GPOS kerning match `CTTypesetterSuggestLineBreak` exactly.
                        let em: (end: Int, visW: Double, metrics: LineFontMetrics, hitHardBreak: Bool)
                        if para.hasBiDiUnits {
                            em = Self.ctBiDiLineBreak(
                                para: para, from: lineStart, maxWidth: availW, bidiIsRTL: curBidiIsRTL,
                                units: unitsBuffer(), ns: ns, allRuns: runs)
                        } else {
                            let segEnd = Int(seg.end)
                            em = Self.arithmeticEmergencyBreak(
                                para: para, from: lineStart, limit: segEnd, maxWidth: availW,
                                units: unitsBuffer(), ns: ns, allRuns: runs)
                        }
                        emitLine(
                            localStart: lineStart, localEnd: em.end, visibleWidth: CGFloat(em.visW),
                            metrics: em.metrics, isHardBreak: em.hitHardBreak)
                        lineStart = em.end
                        while segIdx < segCount && Int(sBuf[segIdx].end) <= em.end { segIdx += 1 }
                        if segIdx < segCount && lineStart < Int(sBuf[segIdx].end) {
                            partialActive = true
                        }
                        broke = true
                        break
                    }

                    if !broke {
                        emitLine(
                            localStart: lineStart, localEnd: pLen, visibleWidth: CGFloat(lineVisW),
                            metrics: curMetrics, isHardBreak: false)
                        segIdx = segCount
                    }
                }
            }
        }

        return TextLayout(
            prepared: self,
            availableWidth: width,
            size: CGSize(width: ceil(maxWidth), height: ceil(y)),
            lines: outLines,
            hasComplexBiDi: hasComplexBiDi)
    }

    // MARK: - Paragraph Preparation

    private static func lookupFontTableIndex(
        _ font: CTFont,
        cache: inout [(font: CTFont, table: FontWidthTable)],
        bmpClusterCaches: inout [[UInt16: (width: Float, metrics: LineFontMetrics)]],
        bmpPairKernCaches: inout [[UInt32: Float]]
    ) -> Int {
        for idx in cache.indices where cache[idx].font === font || CFEqual(cache[idx].font, font) {
            return idx
        }
        let idx = cache.count
        cache.append((font, FontWidthTable.table(for: font)))
        bmpClusterCaches.append([:])
        bmpPairKernCaches.append([:])
        return idx
    }

    @inline(__always)
    private static func couldAttachToPreceding(_ u: UInt16) -> Bool {
        if u <= 0x036F { return true }
        if u >= 0x0483 && u <= 0x0489 { return true }
        if u >= 0x0591 && u <= 0x11FF { return true }
        if u >= 0x1AB0 && u <= 0x1AFF { return true }
        if u >= 0x1DC0 && u <= 0x1DFF { return true }
        if u == 0x200C || u == 0x200D { return true }
        if u >= 0x20D0 && u <= 0x20FF { return true }
        if u == 0x3099 || u == 0x309A { return true }
        if u >= 0xFE00 && u <= 0xFE2F { return true }
        if u == 0xFF9E || u == 0xFF9F { return true }
        return false
    }

    @inline(__always)
    private static func isSimpleBMPCluster(_ units: [UInt16], at i: Int, limit: Int) -> Bool {
        let u = units[i]
        if u >= 0xD800 && u <= 0xDFFF { return false }
        if i + 1 < limit {
            let next = units[i + 1]
            if next >= 0x0300 && couldAttachToPreceding(next) { return false }
        }
        return true
    }

    private static func prepareParagraph(
        styled: StyledParagraph,
        range: Range<Int>,
        runSlice: Range<Int>,
        allRuns: [StyledRun],
        fullText: String,
        nsString: NSString,
        cfString: CFString,
        options: TextLayoutEngine.Options,
        previousTail: (prevText: String, prevRuns: [StyledRun], para: Paragraph)?,
        reusableTokenizer: inout CFStringTokenizer?,
        fontTableCache: inout [(font: CTFont, table: FontWidthTable)],
        bmpClusterCaches: inout [[UInt16: (width: Float, metrics: LineFontMetrics)]],
        bmpPairKernCaches: inout [[UInt32: Float]]
    ) -> Paragraph {
        let pStart = range.lowerBound
        let pLen = range.count

        var hasInlineDec = false
        var hasTabs = false
        let runCount = runSlice.count
        var runTableIndices = [Int](repeating: 0, count: runCount)
        for offset in 0..<runCount {
            let run = allRuns[runSlice.lowerBound + offset]
            let st = run.style
            if st.isInlineCode || st.isUnderlined || st.isStruck || st.linkIndex != nil {
                hasInlineDec = true
            }
            if run.tabInterval > 0 { hasTabs = true }
            runTableIndices[offset] = lookupFontTableIndex(
                run.font.font, cache: &fontTableCache,
                bmpClusterCaches: &bmpClusterCaches, bmpPairKernCaches: &bmpPairKernCaches)
        }
        let defaultMetrics =
            runCount > 0
            ? fontTableCache[runTableIndices[0]].table.baseMetrics
            : LineFontMetrics(ascent: 12, descent: 3, leading: 0)

        // O(appended tail) streaming fast path BEFORE allocating the full UTF-16
        // buffer or scanning the unchanged prefix: checks prefix equality via
        // zero-copy `memcmp`, verifies unchanged runs, scans only newly appended
        // bytes, and tokenizes strictly from the last safe break boundary.
        if options.wraps, !hasTabs, runCount >= 1, let prevTail = previousTail,
            prevTail.para.segments.count >= 4
        {
            let prevLen = prevTail.para.range.count
            let prefixMatches: Bool =
                if pStart == 0, prevTail.para.isPureASCII,
                    let matched = prevTail.prevText.utf8.withContiguousStorageIfAvailable({ a -> Bool? in
                        fullText.utf8.withContiguousStorageIfAvailable { b in
                            guard a.count >= prevLen, b.count >= prevLen,
                                let baseA = a.baseAddress, let baseB = b.baseAddress
                            else { return false }
                            return memcmp(baseA, baseB, prevLen) == 0
                        }
                    }).flatMap({ $0 })
                {
                    matched
                } else {
                    sameTextSlice(prevTail.prevText, fullText, utf16Range: pStart..<(pStart + prevLen))
                }
            if prefixMatches {
                // Find the end of the unchanged prefix of `allRuns` (for single-run,
                // the sole run already matched in `PreparedText.init`).
                let matchedRunEnd: Int
                if runCount == 1 && prevTail.para.runSlice.count == 1 {
                    matchedRunEnd = prevLen
                } else {
                    let prevRuns = prevTail.prevRuns
                    let prevSlice = prevTail.para.runSlice
                    let sharedMax = min(prevSlice.count, runCount)
                    var endU = 0
                    for k in 0..<sharedMax {
                        let a = prevRuns[prevSlice.lowerBound + k]
                        let b = allRuns[runSlice.lowerBound + k]
                        if a == b {
                            endU = min(prevLen, b.range.upperBound - pStart)
                        } else if a.range.lowerBound == b.range.lowerBound,
                            a.style == b.style, a.tabInterval == b.tabInterval,
                            CFEqual(a.font.font, b.font.font),
                            b.range.upperBound > a.range.upperBound
                        {
                            endU = min(prevLen, a.range.upperBound - pStart)
                            break
                        } else {
                            break
                        }
                    }
                    matchedRunEnd = endU
                }

                if matchedRunEnd > 0 {
                    var tailPureASCII = true
                    let checkStart = max(0, matchedRunEnd - 1)
                    var checkRunOffset = 0
                    if runCount > 1 {
                        let targetGlobal = pStart + checkStart
                        var lo = 0
                        var hi = runCount
                        while lo + 1 < hi {
                            let mid = (lo + hi) / 2
                            if allRuns[runSlice.lowerBound + mid].range.lowerBound <= targetGlobal {
                                lo = mid
                            } else {
                                hi = mid
                            }
                        }
                        checkRunOffset = lo
                    }
                    for i in checkStart..<pLen {
                        let gI = pStart + i
                        while checkRunOffset + 1 < runCount,
                            gI >= allRuns[runSlice.lowerBound + checkRunOffset].range.upperBound
                        {
                            checkRunOffset += 1
                        }
                        let u = nsString.character(at: gI)
                        if u >= 0x80 || (u < 0x20 && u != 0x0A) || u == 0x7F {
                            tailPureASCII = false
                            break
                        }
                        let tbl = fontTableCache[runTableIndices[checkRunOffset]].table
                        if tbl.contextualASCIIChars.contains(u) {
                            let prevDigit = i > 0 && nsString.character(at: gI - 1) >= 0x30
                                && nsString.character(at: gI - 1) <= 0x39
                            let nextDigit = i + 1 < pLen && nsString.character(at: gI + 1) >= 0x30
                                && nsString.character(at: gI + 1) <= 0x39
                            if prevDigit || nextDigit {
                                tailPureASCII = false
                                break
                            }
                        }
                    }
                    if tailPureASCII {
                        var keepSegCount = prevTail.para.segments.count - 2
                        while keepSegCount > 0 {
                            let endU = Int(prevTail.para.segments[keepSegCount - 1].end)
                            if endU > 0 && endU < matchedRunEnd && nsString.character(at: pStart + endU - 1) == 0x20 {
                                let prevChar = endU >= 2 ? nsString.character(at: pStart + endU - 2) : 0
                                let prevOK =
                                    endU < 2
                                    || (prevChar != 0x28 && prevChar != 0x5B && prevChar != 0x7B && prevChar != 0x20)
                                let nextU = nsString.character(at: pStart + endU)
                                let nextAlnum =
                                    (nextU >= 0x41 && nextU <= 0x5A) || (nextU >= 0x61 && nextU <= 0x7A)
                                    || (nextU >= 0x30 && nextU <= 0x39)
                                if prevOK && nextAlnum { break }
                            }
                            keepSegCount -= 1
                        }
                        if keepSegCount > 0 {
                            let resume = Int(prevTail.para.segments[keepSegCount - 1].end)
                            let tailLen = pLen - resume
                            var tailUnits = [UInt16](repeating: 0, count: tailLen)
                            nsString.getCharacters(&tailUnits, range: NSRange(location: pStart + resume, length: tailLen))
                            let tailOpps = fastASCIITokenize(tailUnits)
                            var segs: [PreparedSegment] = []
                            segs.reserveCapacity(keepSegCount + tailOpps.count + 4)
                            segs.append(contentsOf: prevTail.para.segments[..<keepSegCount])
                            if runCount == 1 {
                                buildPureASCIISegments(
                                    units: tailUnits, startOffset: 0, outputOffset: resume,
                                    primaryOpps: tailOpps, table: fontTableCache[runTableIndices[0]].table, into: &segs)
                                return Paragraph(
                                    styled: styled, range: range, runSlice: runSlice, isRTL: false,
                                    defaultMetrics: defaultMetrics, extraMetrics: [], segments: segs,
                                    usedInContext: false, isPureASCII: true,
                                    inContextUnitWidths: nil, inContextUnitMetrics: nil,
                                    hasInlineDecorations: hasInlineDec, hasBiDiUnits: false, hasTabUnits: false)
                            } else {
                                var extras = prevTail.para.extraMetrics
                                var extraMap: [LineFontMetrics: UInt16] = [:]
                                extraMap.reserveCapacity(extras.count + 4)
                                for (idx, m) in extras.enumerated() { extraMap[m] = UInt16(idx + 2) }
                                buildMultiRunPureASCIISegments(
                                    units: tailUnits, pStart: pStart, outputOffset: resume, totalParaLen: pLen,
                                    primaryOpps: tailOpps, runSlice: runSlice, allRuns: allRuns,
                                    runTableIndices: runTableIndices, fontTableCache: fontTableCache,
                                    defaultMetrics: defaultMetrics, extras: &extras, extraMap: &extraMap, into: &segs)
                                return Paragraph(
                                    styled: styled, range: range, runSlice: runSlice, isRTL: false,
                                    defaultMetrics: defaultMetrics, extraMetrics: extras, segments: segs,
                                    usedInContext: false, isPureASCII: true,
                                    inContextUnitWidths: nil, inContextUnitMetrics: nil,
                                    hasInlineDecorations: hasInlineDec, hasBiDiUnits: false, hasTabUnits: false)
                            }
                        }
                    }
                }
            }
        }

        var units = [UInt16](repeating: 0, count: pLen)
        nsString.getCharacters(&units, range: NSRange(location: pStart, length: pLen))
        let isRTL = options.wraps && options.alignsRTLToWidth
            && TextLayoutEngine.paragraphIsRTL(nsString, startingAt: pStart)

        // Scan units to classify pure ASCII vs verified non-ASCII vs per-segment
        // or whole-paragraph in-context shaping.
        var wholeParaInContext = !options.wraps || hasTabs
        var hasInContextSegment = false
        var inContextUnitCount = 0
        var pureASCII = true
        var hasBiDiUnits = isRTL
        var hasTabUnits = false
        var hasHangul = false
        var hasKanaOrHan = false
        var localRunIdx = 0
        for i in 0..<pLen {
            let globalI = pStart + i
            while localRunIdx + 1 < runCount, globalI >= allRuns[runSlice.lowerBound + localRunIdx].range.upperBound {
                localRunIdx += 1
            }
            let u = units[i]
            if u >= 0x80 {
                pureASCII = false
                if TextLayoutEngine.isBiDiCodeUnit(u) {
                    hasBiDiUnits = true
                    wholeParaInContext = true
                }
                if !wholeParaInContext {
                    if (u >= 0xAC00 && u <= 0xD7AF) || (u >= 0x3130 && u <= 0x318F) {
                        hasHangul = true
                    } else if (u >= 0x3000 && u <= 0x30FF) || (u >= 0x4E00 && u <= 0x9FFF)
                        || (u >= 0xF900 && u <= 0xFAFF)
                    {
                        hasKanaOrHan = true
                    }
                    let scalar: UInt32
                    if u >= 0xD800 && u <= 0xDBFF && i + 1 < pLen {
                        let lo = units[i + 1]
                        scalar =
                            (lo >= 0xDC00 && lo <= 0xDFFF)
                            ? (0x10000 + ((UInt32(u - 0xD800) << 10) | UInt32(lo - 0xDC00)))
                            : UInt32(u)
                    } else if u >= 0xDC00 && u <= 0xDFFF {
                        continue
                    } else {
                        scalar = UInt32(u)
                    }
                    if FontWidthTable.scalarNeedsInContextShaping(scalar) || TextLayoutEngine.endsLine(u) {
                        hasInContextSegment = true
                        inContextUnitCount += 1
                    }
                }
            } else if (u < 0x20 && u != 0x0A) || u == 0x7F {
                // Control chars including \t, \r, \v, \f, DEL: let in-context Core Text measure exact advances.
                if u == 0x09 { hasTabUnits = true }
                pureASCII = false
                wholeParaInContext = true
            } else if !wholeParaInContext,
                fontTableCache[runTableIndices[localRunIdx]].table.contextualASCIIChars.contains(u)
            {
                let prevDigit = i > 0 && units[i - 1] >= 0x30 && units[i - 1] <= 0x39
                let nextDigit = i + 1 < pLen && units[i + 1] >= 0x30 && units[i + 1] <= 0x39
                if prevDigit || nextDigit {
                    hasInContextSegment = true
                    inContextUnitCount += 1
                }
            }
        }
        // Core Text's sticky CJK fallback keeps Hangul's font (AppleSDGothicNeo)
        // onto adjacent Kana/Han, changing their advance vs standalone lookup.
        if hasHangul && hasKanaOrHan { wholeParaInContext = true }
        // Dense complex-script paragraphs (Arabic, Thai, Devanagari, Myanmar)
        // batch faster in 2 KB Core Text windows than one CTLine per segment.
        if inContextUnitCount * 8 >= pLen { wholeParaInContext = true }

        // Tokenize line-break opportunities: pure-ASCII paragraphs use our exact
        // pure-Swift UAX #14 state machine (0 diffs vs CFStringTokenizer, 5-10×
        // faster on iPhone 14); non-ASCII paragraphs use CFStringTokenizer.
        let primaryOpps: [Int] =
            if pureASCII {
                fastASCIITokenize(units)
            } else {
                tokenizeLineBreaks(
                    cf: cfString, baseOffset: pStart, units: units, parallelThreshold: parallelTokenizerThreshold,
                    reusable: &reusableTokenizer)
            }

        // If a single unbroken token > 128 UTF-16 units contains an in-context
        // trigger (possible emergency mid-word wrap), use whole-paragraph
        // in-context unit widths so `fit(width:)` breaks identically to Core Text.
        if !wholeParaInContext && hasInContextSegment {
            var prev = 0
            for opp in primaryOpps {
                if opp - prev > 128 {
                    wholeParaInContext = true
                    break
                }
                prev = opp
            }
            if !wholeParaInContext && pLen - prev > 128 {
                wholeParaInContext = true
            }
        }

        let needInContext = wholeParaInContext

        var segs: [PreparedSegment] = []
        segs.reserveCapacity(primaryOpps.count + 4)
        var extras: [LineFontMetrics] = []
        var extraMap: [LineFontMetrics: UInt16] = [:]

        @inline(__always)
        func packFlags(metrics m: LineFontMetrics, isPrimary: Bool, isHard: Bool, hasTrail: Bool) -> UInt16 {
            let mIdx: UInt16
            if m.isZero {
                mIdx = 0
            } else if m == defaultMetrics {
                mIdx = 1
            } else if let existing = extraMap[m] {
                mIdx = existing
            } else {
                extras.append(m)
                let idx = UInt16(extras.count + 1)
                extraMap[m] = idx
                mIdx = idx
            }
            var v = mIdx & 0x1FFF
            if isPrimary { v |= 0x2000 }
            if isHard { v |= 0x4000 }
            if hasTrail { v |= 0x8000 }
            return v
        }

        if needInContext {
            var unitW = [Float](repeating: 0, count: pLen)
            var unitMetrics = [LineFontMetrics](repeating: .zero, count: pLen)
            var chunkDir: CTWritingDirection? =
                hasBiDiUnits
                ? (TextLayoutEngine.bidiParagraphIsRTL(nsString, startingAt: pStart) ? .rightToLeft : .leftToRight)
                : nil
            var s = 0
            while s < pLen {
                var e = min(pLen, s + 2_048)
                for k in s..<e where TextLayoutEngine.endsLine(units[k]) {
                    e = k + 1
                    break
                }
                let lo = (s > 0 && !TextLayoutEngine.endsLine(units[s - 1])) ? max(0, s - 64) : s
                var hi = min(pLen, e + 64)
                for k in e..<hi where TextLayoutEngine.endsLine(units[k]) {
                    hi = k
                    break
                }
                let subAttr = StyledText.attributedSlice(
                    of: nsString, range: (pStart + lo)..<(pStart + hi), runs: allRuns,
                    baseWritingDirection: chunkDir)
                let line = CTLineCreateWithAttributedString(subAttr)
                for run in (CTLineGetGlyphRuns(line) as? [CTRun] ?? []) {
                    let gc = CTRunGetGlyphCount(run)
                    guard gc > 0 else { continue }
                    var pos = [CGPoint](repeating: .zero, count: gc)
                    var idx = [CFIndex](repeating: 0, count: gc)
                    CTRunGetPositions(run, CFRange(), &pos)
                    CTRunGetStringIndices(run, CFRange(), &idx)
                    var ra: CGFloat = 0
                    var rd: CGFloat = 0
                    var rl: CGFloat = 0
                    let rw = CTRunGetTypographicBounds(run, CFRange(), &ra, &rd, &rl)
                    let rm = LineFontMetrics(ascent: Float(ra), descent: Float(rd), leading: Float(rl))
                    let runRight = Double(pos[0].x) + rw
                    let isRTLRun = CTRunGetStatus(run).contains(.rightToLeft)
                    for m in 0..<gc {
                        var u = lo + idx[m]
                        let w = (m + 1 < gc) ? Double(pos[m + 1].x - pos[m].x) : (runRight - Double(pos[m].x))
                        // In RTL runs (e.g. SF Arabic), Core Text attaches negative-advance
                        // kerning glyphs to the logically earlier unit (`idx[m]`) immediately
                        // after the logically later unit (`idx[m - 1]`). That kern only takes
                        // effect once both units fit on the line, so attribute it to `idx[m - 1]`.
                        if isRTLRun && w < 0 && m > 0 && idx[m - 1] > idx[m] {
                            u = lo + idx[m - 1]
                        }
                        guard u >= s && u < e else { continue }
                        unitW[u] += Float(w)
                        unitMetrics[u].formMax(rm)
                    }
                }
                // Ensure glyphless cluster-starting characters (hard breaks,
                // ZWSP, BiDi marks, soft hyphens) carry their own run font's
                // vertical metrics, while skipping combining marks and variation
                // selectors that attach to a preceding base glyph.
                var rIdx = runSlice.lowerBound
                for u in s..<e {
                    if units[u] == 0x09 {
                        // Tab width depends on x within each wrapped line.
                        unitW[u] = 0
                    }
                    if unitMetrics[u].isZero && units[u] != 0x2060
                        && TextLayoutEngine.startsCluster(nsString, at: pStart + u)
                    {
                        let gU = pStart + u
                        while rIdx + 1 < runSlice.upperBound, gU >= allRuns[rIdx].range.upperBound { rIdx += 1 }
                        unitMetrics[u] = fontTableCache[runTableIndices[rIdx - runSlice.lowerBound]].table.baseMetrics
                    }
                }
                if hasBiDiUnits && e < pLen && e > s && TextLayoutEngine.isBiDiParagraphSeparator(units[e - 1]) {
                    chunkDir =
                        TextLayoutEngine.bidiParagraphIsRTL(nsString, startingAt: pStart + e)
                        ? .rightToLeft : .leftToRight
                }
                s = e
            }

            emitSegments(units: units, startOffset: 0, primaryOpps: primaryOpps, out: &segs) {
                segStart, segEnd, isPrimary, isHard in
                let visEnd = Self.visibleEnd(in: units, from: segStart, to: segEnd)
                var tot: Double = 0
                var vis: Double = 0
                var m = LineFontMetrics.zero
                for i in segStart..<segEnd {
                    m.formMax(unitMetrics[i])
                    if !TextLayoutEngine.endsLine(units[i]) {
                        tot += Double(unitW[i])
                        if i < visEnd { vis = tot }
                    }
                }
                let hasBreakSpace =
                    visEnd < segEnd && !isHard && FontWidthTable.isBreakableWhitespace(units[visEnd])
                return PreparedSegment(
                    end: UInt32(segEnd),
                    totalWidth: Float(tot),
                    visibleWidth: Float(vis),
                    metricsAndFlags: packFlags(
                        metrics: m, isPrimary: isPrimary, isHard: isHard, hasTrail: hasBreakSpace))
            }

            return Paragraph(
                styled: styled, range: range, runSlice: runSlice, isRTL: isRTL,
                defaultMetrics: defaultMetrics, extraMetrics: extras, segments: segs,
                usedInContext: true, isPureASCII: false,
                inContextUnitWidths: unitW, inContextUnitMetrics: unitMetrics,
                hasInlineDecorations: hasInlineDec, hasBiDiUnits: hasBiDiUnits, hasTabUnits: hasTabUnits)
        }

        if pureASCII && !hasInContextSegment && runCount == 1 {
            buildPureASCIISegments(
                units: units, startOffset: 0, primaryOpps: primaryOpps,
                table: fontTableCache[runTableIndices[0]].table, into: &segs)
            return Paragraph(
                styled: styled, range: range, runSlice: runSlice, isRTL: isRTL,
                defaultMetrics: defaultMetrics, extraMetrics: [], segments: segs,
                usedInContext: false, isPureASCII: true,
                inContextUnitWidths: nil, inContextUnitMetrics: nil,
                hasInlineDecorations: hasInlineDec, hasBiDiUnits: false, hasTabUnits: false)
        }

        if pureASCII && !hasInContextSegment {
            buildMultiRunPureASCIISegments(
                units: units, pStart: pStart, outputOffset: 0, totalParaLen: pLen,
                primaryOpps: primaryOpps, runSlice: runSlice, allRuns: allRuns,
                runTableIndices: runTableIndices, fontTableCache: fontTableCache,
                defaultMetrics: defaultMetrics, extras: &extras, extraMap: &extraMap, into: &segs)
            return Paragraph(
                styled: styled, range: range, runSlice: runSlice, isRTL: isRTL,
                defaultMetrics: defaultMetrics, extraMetrics: extras, segments: segs,
                usedInContext: false, isPureASCII: true,
                inContextUnitWidths: nil, inContextUnitMetrics: nil,
                hasInlineDecorations: hasInlineDec, hasBiDiUnits: false, hasTabUnits: false)
        }

        // General table path: multi-run spans, verified non-ASCII scripts, and
        // paragraphs with scattered in-context segments (e.g. SF Pro `1:2` or
        // an occasional VS16 emoji / combining mark). Only the specific
        // triggering segment uses `CTLineCreateWithAttributedString`; all
        // remaining segments stay on O(1) `FontWidthTable` lookups.
        var spanIdx = 0
        emitSegments(units: units, startOffset: 0, primaryOpps: primaryOpps, out: &segs) {
            segStart, segEnd, isPrimary, isHard in
            let visEnd = Self.visibleEnd(in: units, from: segStart, to: segEnd)
            let hasBreakSpace =
                visEnd < segEnd && !isHard && FontWidthTable.isBreakableWhitespace(units[visEnd])

            if hasInContextSegment {
                var segNeedsInContext = false
                var checkRun = spanIdx
                for ci in segStart..<segEnd {
                    let gci = pStart + ci
                    while checkRun + 1 < runCount, gci >= allRuns[runSlice.lowerBound + checkRun].range.upperBound {
                        checkRun += 1
                    }
                    let u = units[ci]
                    if u >= 0x80 {
                        let scalar: UInt32
                        if u >= 0xD800 && u <= 0xDBFF && ci + 1 < segEnd {
                            let lo = units[ci + 1]
                            scalar =
                                (lo >= 0xDC00 && lo <= 0xDFFF)
                                ? (0x10000 + ((UInt32(u - 0xD800) << 10) | UInt32(lo - 0xDC00)))
                                : UInt32(u)
                        } else if u >= 0xDC00 && u <= 0xDFFF {
                            continue
                        } else {
                            scalar = UInt32(u)
                        }
                        if FontWidthTable.scalarNeedsInContextShaping(scalar) || TextLayoutEngine.endsLine(u) {
                            segNeedsInContext = true
                            break
                        }
                    } else if fontTableCache[runTableIndices[checkRun]].table.contextualASCIIChars.contains(u) {
                        let prevDigit = ci > 0 && units[ci - 1] >= 0x30 && units[ci - 1] <= 0x39
                        let nextDigit = ci + 1 < pLen && units[ci + 1] >= 0x30 && units[ci + 1] <= 0x39
                        if prevDigit || nextDigit {
                            segNeedsInContext = true
                            break
                        }
                    }
                }
                if segNeedsInContext {
                    // Advance `spanIdx` past this segment so subsequent table segments stay aligned.
                    while spanIdx + 1 < runCount,
                        (pStart + segEnd - 1) >= allRuns[runSlice.lowerBound + spanIdx].range.upperBound
                    {
                        spanIdx += 1
                    }
                    var contentEnd = segEnd
                    while contentEnd > segStart && TextLayoutEngine.endsLine(units[contentEnd - 1]) {
                        contentEnd -= 1
                    }
                    var tot: Double = 0
                    var vis: Double = 0
                    var m = LineFontMetrics.zero
                    if contentEnd > segStart {
                        let subAttr = StyledText.attributedSlice(
                            of: nsString, range: (pStart + segStart)..<(pStart + contentEnd), runs: allRuns)
                        let ctLine = CTLineCreateWithAttributedString(subAttr)
                        tot = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
                        let trailW = CTLineGetTrailingWhitespaceWidth(ctLine)
                        vis = max(0, tot - trailW)
                        for run in (CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []) {
                            var ra: CGFloat = 0
                            var rd: CGFloat = 0
                            var rl: CGFloat = 0
                            _ = CTRunGetTypographicBounds(run, CFRange(), &ra, &rd, &rl)
                            m.formMax(LineFontMetrics(ascent: Float(ra), descent: Float(rd), leading: Float(rl)))
                        }
                    }
                    if m.isZero {
                        m = fontTableCache[runTableIndices[spanIdx]].table.baseMetrics
                    }
                    return PreparedSegment(
                        end: UInt32(segEnd),
                        totalWidth: Float(tot),
                        visibleWidth: Float(vis),
                        metricsAndFlags: packFlags(
                            metrics: m, isPrimary: isPrimary, isHard: isHard, hasTrail: hasBreakSpace))
                }
            }

            var tot: Double = 0
            var vis: Double = 0
            var m = LineFontMetrics.zero
            var i = segStart
            while i < segEnd {
                let globalI = pStart + i
                while spanIdx + 1 < runCount, globalI >= allRuns[runSlice.lowerBound + spanIdx].range.upperBound {
                    spanIdx += 1
                }
                let run = allRuns[runSlice.lowerBound + spanIdx]
                let tIdx = runTableIndices[spanIdx]
                let tbl = fontTableCache[tIdx].table
                let runParaEnd = min(pLen, run.range.upperBound - pStart)
                let u = units[i]
                if u == 0x0A {
                    m.formMax(tbl.baseMetrics)
                    i += 1
                    continue
                }
                if u < 0x80 {
                    m.formMax(tbl.baseMetrics)
                    var w = Double(tbl.asciiWidths[Int(u)])
                    let nextGlobal = globalI + 1
                    if i + 1 < runParaEnd {
                        let nu = units[i + 1]
                        if nu < 0x80 && nu != 0x0A {
                            if tbl.hasASCIIKerning { w += Double(tbl.asciiKern[Int(u) * 128 + Int(nu)]) }
                        } else if nu != 0x0A {
                            if isSimpleBMPCluster(units, at: i + 1, limit: runParaEnd) {
                                let bw = tbl.bmpCluster(nu, local: &bmpClusterCaches[tIdx]).width
                                w += Double(
                                    tbl.bmpPairKern(
                                        u, nu, widthA: tbl.asciiWidths[Int(u)], widthB: bw,
                                        local: &bmpPairKernCaches[tIdx]))
                            } else if let scalar = UnicodeScalar(u) {
                                let nr = nsString.rangeOfComposedCharacterSequence(at: nextGlobal)
                                let bStr = nsString.substring(with: nr)
                                let bw = tbl.nonASCIICluster(bStr).width
                                w += Double(
                                    tbl.nonASCIIPairKern(
                                        String(scalar), bStr, widthA: tbl.asciiWidths[Int(u)], widthB: bw))
                            }
                        }
                    }
                    tot += w
                    if i < visEnd { vis = tot }
                    i += 1
                } else if isSimpleBMPCluster(units, at: i, limit: runParaEnd) {
                    let (aw, am) = tbl.bmpCluster(u, local: &bmpClusterCaches[tIdx])
                    m.formMax(am)
                    var w = Double(aw)
                    if i + 1 < runParaEnd && units[i + 1] != 0x0A {
                        let nu = units[i + 1]
                        if nu < 0x80 {
                            w += Double(
                                tbl.bmpPairKern(
                                    u, nu, widthA: aw, widthB: tbl.asciiWidths[Int(nu)],
                                    local: &bmpPairKernCaches[tIdx]))
                        } else if isSimpleBMPCluster(units, at: i + 1, limit: runParaEnd) {
                            let bw = tbl.bmpCluster(nu, local: &bmpClusterCaches[tIdx]).width
                            w += Double(
                                tbl.bmpPairKern(u, nu, widthA: aw, widthB: bw, local: &bmpPairKernCaches[tIdx]))
                        } else {
                            let nr = nsString.rangeOfComposedCharacterSequence(at: globalI + 1)
                            let bStr = nsString.substring(with: nr)
                            let bw = tbl.nonASCIICluster(bStr).width
                            let aStr = String(utf16CodeUnits: [u], count: 1)
                            w += Double(tbl.nonASCIIPairKern(aStr, bStr, widthA: aw, widthB: bw))
                        }
                    }
                    tot += w
                    if i < visEnd { vis = tot }
                    i += 1
                } else {
                    let r = nsString.rangeOfComposedCharacterSequence(at: globalI)
                    let cGlobalEnd = min(NSMaxRange(r), min(run.range.upperBound, pStart + pLen))
                    let cLen = max(1, cGlobalEnd - globalI)
                    let aStr = nsString.substring(with: NSRange(location: globalI, length: cLen))
                    let (aw, am) = tbl.nonASCIICluster(aStr)
                    m.formMax(am)
                    var w = Double(aw)
                    if cGlobalEnd < run.range.upperBound && (i + cLen) < pLen && units[i + cLen] != 0x0A {
                        let nu = units[i + cLen]
                        if nu < 0x80, let scalar = UnicodeScalar(nu) {
                            let bStr = String(scalar)
                            w += Double(
                                tbl.nonASCIIPairKern(aStr, bStr, widthA: aw, widthB: tbl.asciiWidths[Int(nu)]))
                        } else if nu >= 0x80 {
                            let nr = nsString.rangeOfComposedCharacterSequence(at: cGlobalEnd)
                            let bStr = nsString.substring(with: nr)
                            let bw = tbl.nonASCIICluster(bStr).width
                            w += Double(tbl.nonASCIIPairKern(aStr, bStr, widthA: aw, widthB: bw))
                        }
                    }
                    tot += w
                    if i < visEnd { vis = tot }
                    i += cLen
                }
            }
            return PreparedSegment(
                end: UInt32(segEnd),
                totalWidth: Float(tot),
                visibleWidth: Float(vis),
                metricsAndFlags: packFlags(
                    metrics: m, isPrimary: isPrimary, isHard: isHard, hasTrail: hasBreakSpace))
        }

        return Paragraph(
            styled: styled, range: range, runSlice: runSlice, isRTL: isRTL,
            defaultMetrics: defaultMetrics, extraMetrics: extras, segments: segs,
            usedInContext: false, isPureASCII: pureASCII,
            inContextUnitWidths: nil, inContextUnitMetrics: nil,
            hasInlineDecorations: hasInlineDec, hasBiDiUnits: hasBiDiUnits, hasTabUnits: false)
    }

    private static func buildMultiRunPureASCIISegments(
        units: [UInt16],
        pStart: Int,
        outputOffset: Int,
        totalParaLen: Int,
        primaryOpps: [Int],
        runSlice: Range<Int>,
        allRuns: [StyledRun],
        runTableIndices: [Int],
        fontTableCache: [(font: CTFont, table: FontWidthTable)],
        defaultMetrics: LineFontMetrics,
        extras: inout [LineFontMetrics],
        extraMap: inout [LineFontMetrics: UInt16],
        into out: inout [PreparedSegment]
    ) {
        let runCount = runSlice.count
        var spanIdx = 0
        if outputOffset > 0 && runCount > 1 {
            let targetGlobal = pStart + outputOffset
            var lo = 0
            var hi = runCount
            while lo + 1 < hi {
                let mid = (lo + hi) / 2
                if allRuns[runSlice.lowerBound + mid].range.lowerBound <= targetGlobal { lo = mid } else { hi = mid }
            }
            spanIdx = lo
        }
        units.withUnsafeBufferPointer { uBuf in
            emitSegments(units: units, startOffset: 0, primaryOpps: primaryOpps, out: &out) {
                segStart, segEnd, isPrimary, isHard in
                var visEnd = segEnd
                while visEnd > segStart && (uBuf[visEnd - 1] == 0x20 || uBuf[visEnd - 1] == 0x0A) {
                    visEnd -= 1
                }
                var tot: Double = 0
                var vis: Double = 0
                var m = LineFontMetrics.zero
                for i in segStart..<segEnd {
                    let globalI = pStart + outputOffset + i
                    while spanIdx + 1 < runCount, globalI >= allRuns[runSlice.lowerBound + spanIdx].range.upperBound {
                        spanIdx += 1
                    }
                    let run = allRuns[runSlice.lowerBound + spanIdx]
                    let tbl = fontTableCache[runTableIndices[spanIdx]].table
                    m.formMax(tbl.baseMetrics)
                    let u = Int(uBuf[i])
                    if u == 0x0A { continue }
                    var w = Double(tbl.asciiWidths[u])
                    if tbl.hasASCIIKerning, globalI + 1 < run.range.upperBound, outputOffset + i + 1 < totalParaLen,
                        i + 1 < uBuf.count
                    {
                        let nu = Int(uBuf[i + 1])
                        if nu != 0x0A && nu < 128 { w += Double(tbl.asciiKern[u * 128 + nu]) }
                    }
                    tot += w
                    if i < visEnd { vis = tot }
                }
                let mIdx: UInt16
                if m.isZero {
                    mIdx = 0
                } else if m == defaultMetrics {
                    mIdx = 1
                } else if let existing = extraMap[m] {
                    mIdx = existing
                } else {
                    extras.append(m)
                    let idx = UInt16(extras.count + 1)
                    extraMap[m] = idx
                    mIdx = idx
                }
                var flags = mIdx & 0x1FFF
                if isPrimary { flags |= 0x2000 }
                if isHard { flags |= 0x4000 }
                if visEnd < segEnd && !isHard { flags |= 0x8000 }
                return PreparedSegment(
                    end: UInt32(outputOffset + segEnd), totalWidth: Float(tot), visibleWidth: Float(vis),
                    metricsAndFlags: flags)
            }
        }
    }

    private static func buildPureASCIISegments(
        units: [UInt16],
        startOffset: Int,
        outputOffset: Int = 0,
        primaryOpps: [Int],
        table: FontWidthTable,
        into out: inout [PreparedSegment]
    ) {
        let pLen = units.count
        let widths = table.asciiWidths
        let kern = table.asciiKern
        let hasKern = table.hasASCIIKerning
        widths.withUnsafeBufferPointer { wBuf in
            kern.withUnsafeBufferPointer { kBuf in
                units.withUnsafeBufferPointer { uBuf in
                    emitSegments(units: units, startOffset: startOffset, primaryOpps: primaryOpps, out: &out) {
                        segStart, segEnd, isPrimary, isHard in
                        var visEnd = segEnd
                        while visEnd > segStart && (uBuf[visEnd - 1] == 0x20 || uBuf[visEnd - 1] == 0x0A) {
                            visEnd -= 1
                        }
                        var tot: Double = 0
                        var vis: Double = 0
                        for i in segStart..<segEnd {
                            let u = Int(uBuf[i])
                            if u == 0x0A { continue }
                            var w = Double(wBuf[u])
                            if hasKern && i + 1 < pLen {
                                let nu = Int(uBuf[i + 1])
                                if nu != 0x0A && nu < 128 {
                                    w += Double(kBuf[u * 128 + nu])
                                }
                            }
                            tot += w
                            if i < visEnd { vis = tot }
                        }
                        var flags: UInt16 = 1  // paragraph default metrics
                        if isPrimary { flags |= 0x2000 }
                        if isHard { flags |= 0x4000 }
                        if visEnd < segEnd && !isHard { flags |= 0x8000 }
                        return PreparedSegment(
                            end: UInt32(outputOffset + segEnd), totalWidth: Float(tot), visibleWidth: Float(vis),
                            metricsAndFlags: flags)
                    }
                }
            }
        }
    }

    // MARK: - Tokenizer & Segment Emission

    /// Exact Apple ICU / `CFStringTokenizer` UAX #14 line-break class map for
    /// printable ASCII (`0x20...0x7E`) + `LF` (`0x0A`).
    private static let asciiLBClass: [UInt8] = {
        var t = [UInt8](repeating: 14, count: 128)  // 14 = AL
        t[0x0A] = 0  // LF
        t[0x20] = 1  // SP
        for c in "([{".utf8 { t[Int(c)] = 2 }  // OP
        for c in ")]".utf8 { t[Int(c)] = 3 }  // CP
        t[Int(UInt8(ascii: "}"))] = 4  // CL
        for c in "\"'".utf8 { t[Int(c)] = 5 }  // QU
        for c in "!?".utf8 { t[Int(c)] = 6 }  // EX
        t[Int(UInt8(ascii: "/"))] = 7  // SY
        for c in ",.:;".utf8 { t[Int(c)] = 8 }  // IS
        t[Int(UInt8(ascii: "-"))] = 9  // HY
        t[Int(UInt8(ascii: "|"))] = 10  // BA
        for c in "$+\\".utf8 { t[Int(c)] = 11 }  // PR
        t[Int(UInt8(ascii: "%"))] = 12  // PO
        for c in UInt8(ascii: "0")...UInt8(ascii: "9") { t[Int(c)] = 13 }  // NU
        return t
    }()

    /// Pure-Swift UAX #14 line-break tokenizer for pure ASCII (`0x0A`,
    /// `0x20...0x7E`), 4.6× faster than `CFStringTokenizer` (ICU was 6.4 s
    /// of an iPhone 14 trace of a 20 MB chat). `ASCIILineBreakParityTests`
    /// holds it to the system's breaks on every OS the tests run on.
    static func fastASCIITokenize(_ units: [UInt16]) -> [Int] {
        let n = units.count
        guard n > 0 else { return [] }
        var out: [Int] = []
        out.reserveCapacity(max(8, n / 5))
        var nonSPBefore: UInt8 = 255
        var inNumeric = false
        var numClosed = false

        units.withUnsafeBufferPointer { uBuf in
            asciiLBClass.withUnsafeBufferPointer { cBuf in
                var i = 0
                while i < n {
                    let c = cBuf[Int(uBuf[i])]
                    if c == 0 {
                        out.append(i + 1)
                        nonSPBefore = 255
                        inNumeric = false
                        numClosed = false
                        i += 1
                        continue
                    }
                    let prevNonSP = nonSPBefore
                    let prevInNum = inNumeric
                    if c != 1 {
                        nonSPBefore = c
                        if c == 13 {
                            inNumeric = true
                            numClosed = false
                        } else if (c == 7 || c == 8) && prevInNum {
                            inNumeric = true
                            numClosed = false
                        } else if (c == 3 || c == 4) && prevInNum {
                            inNumeric = false
                            numClosed = true
                        } else {
                            inNumeric = false
                            numClosed = false
                        }
                    } else {
                        inNumeric = false
                        numClosed = false
                    }

                    let nextIdx = i + 1
                    if nextIdx >= n {
                        out.append(n)
                        break
                    }
                    let nc = cBuf[Int(uBuf[nextIdx])]
                    if nc == 0 || nc == 1 {
                        i += 1
                        continue
                    }

                    var allow = false
                    if c == 1 {
                        if prevNonSP == 2 {
                            allow = false
                        } else if nc == 3 || nc == 4 || nc == 6 || nc == 7 {
                            allow = false
                        } else if nc == 8 {
                            allow = nextIdx + 1 < n && cBuf[Int(uBuf[nextIdx + 1])] == 13
                        } else {
                            allow = true
                        }
                    } else {
                        switch c {
                        case 6, 10:
                            allow = nc == 14 || nc == 13 || nc == 11 || nc == 12 || nc == 2
                        case 7:
                            allow =
                                (prevInNum && (nc == 13 || nc == 11 || nc == 12))
                                ? false
                                : (nc == 14 || nc == 13 || nc == 11 || nc == 12 || nc == 2)
                        case 4:
                            allow =
                                (numClosed && (nc == 11 || nc == 12))
                                ? false
                                : (nc == 14 || nc == 13 || nc == 11 || nc == 12 || nc == 2)
                        case 3:
                            allow = (numClosed && (nc == 11 || nc == 12)) ? false : (nc == 11 || nc == 12 || nc == 2)
                        case 8:
                            allow = (prevInNum && (nc == 11 || nc == 12)) ? false : (nc == 11 || nc == 12 || nc == 2)
                        case 9:
                            if nc == 11 || nc == 12 || nc == 2 {
                                allow = true
                            } else if nc == 14 {
                                allow = i > 0 && cBuf[Int(uBuf[i - 1])] != 1 && cBuf[Int(uBuf[i - 1])] != 0
                            }
                        case 11, 12:
                            if nc == 11 || nc == 12 {
                                allow = true
                            } else if nc == 2 {
                                // `(PR | PO) × OP IS? NU` (`$(1`, `$(.5`); ICU
                                // breaks before `(-1`.
                                let afterOP = nextIdx + 1 < n ? cBuf[Int(uBuf[nextIdx + 1])] : 255
                                if afterOP == 13 {
                                    allow = false
                                } else if afterOP == 8 && nextIdx + 2 < n && cBuf[Int(uBuf[nextIdx + 2])] == 13 {
                                    allow = false
                                } else {
                                    allow = true
                                }
                            }
                        default:
                            allow = false
                        }
                    }
                    if allow { out.append(nextIdx) }
                    i += 1
                }
            }
        }
        return out
    }

    private static func tokenizeLineBreaks(
        cf: CFString, baseOffset: Int, units: [UInt16], parallelThreshold: Int,
        reusable: inout CFStringTokenizer?
    ) -> [Int] {
        let n = units.count
        guard n > 0 else { return [] }
        if n < parallelThreshold {
            return tokenizeRange(
                cf: cf, range: CFRange(location: baseOffset, length: n), baseOffset: baseOffset, reusable: &reusable)
        }
        let workers = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
        var cuts = [0]
        for k in 1..<workers {
            var q = n * k / workers
            let limit = min(n - 1, q + 4_096)
            var found = false
            while q < limit {
                if units[q] == 0x20 {
                    let prevOK =
                        q == 0
                        || (units[q - 1] != 0x28 && units[q - 1] != 0x5B && units[q - 1] != 0x7B
                            && units[q - 1] != 0x20)
                    let next = units[q + 1]
                    let nextAlnum =
                        (next >= 0x41 && next <= 0x5A) || (next >= 0x61 && next <= 0x7A)
                        || (next >= 0x30 && next <= 0x39)
                    if prevOK && nextAlnum {
                        cuts.append(q + 1)
                        found = true
                        break
                    }
                }
                q += 1
            }
            if !found { break }
        }
        cuts.append(n)
        if cuts.count <= 2 {
            return tokenizeRange(
                cf: cf, range: CFRange(location: baseOffset, length: n), baseOffset: baseOffset, reusable: &reusable)
        }
        let fixedCuts = cuts
        let chunkCount = fixedCuts.count - 1
        var parts = [[Int]](repeating: [], count: chunkCount)
        nonisolated(unsafe) let cfStrUnsafe = cf
        parts.withUnsafeMutableBufferPointer { buf in
            nonisolated(unsafe) let rawBuf = buf
            DispatchQueue.concurrentPerform(iterations: chunkCount) { k in
                var localTok: CFStringTokenizer?
                rawBuf[k] = tokenizeRange(
                    cf: cfStrUnsafe,
                    range: CFRange(location: baseOffset + fixedCuts[k], length: fixedCuts[k + 1] - fixedCuts[k]),
                    baseOffset: baseOffset,
                    reusable: &localTok)
            }
        }
        var total = 0
        for p in parts { total += p.count }
        var out: [Int] = []
        out.reserveCapacity(total)
        for p in parts { out.append(contentsOf: p) }
        return out
    }

    static func tokenizeRange(
        cf: CFString, range: CFRange, baseOffset: Int, reusable: inout CFStringTokenizer?
    ) -> [Int] {
        let tok: CFStringTokenizer
        if let existing = reusable {
            CFStringTokenizerSetString(existing, cf, range)
            tok = existing
        } else if let created = CFStringTokenizerCreate(nil, cf, range, kCFStringTokenizerUnitLineBreak, nil) {
            reusable = created
            tok = created
        } else {
            return [(range.location + range.length) - baseOffset]
        }
        var out: [Int] = []
        out.reserveCapacity(max(8, range.length / 5))
        while !CFStringTokenizerAdvanceToNextToken(tok).isEmpty {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            let localEnd = (r.location + r.length) - baseOffset
            if out.last != localEnd { out.append(localEnd) }
        }
        let rangeEnd = (range.location + range.length) - baseOffset
        if out.last != rangeEnd { out.append(rangeEnd) }
        return out
    }

    private static func emitSegments(
        units: [UInt16],
        startOffset: Int,
        primaryOpps: [Int],
        out: inout [PreparedSegment],
        build: (_ start: Int, _ end: Int, _ isPrimary: Bool, _ isHardBreak: Bool) -> PreparedSegment
    ) {
        var prev = startOffset
        for opp in primaryOpps where opp > prev {
            var segStart = prev
            var i = prev
            while i < opp {
                let u = units[i]
                if TextLayoutEngine.endsLine(u) {
                    // Keep \r\n together as one hard break.
                    let breakEnd = (u == 0x0D && i + 1 < opp && units[i + 1] == 0x0A) ? i + 2 : i + 1
                    out.append(build(segStart, breakEnd, true, true))
                    segStart = breakEnd
                    i = breakEnd
                } else if FontWidthTable.isBreakableWhitespace(u) {
                    while i < opp && FontWidthTable.isBreakableWhitespace(units[i]) { i += 1 }
                    if i < opp && !TextLayoutEngine.endsLine(units[i]) {
                        out.append(build(segStart, i, false, false))
                        segStart = i
                    }
                } else {
                    i += 1
                }
            }
            if segStart < opp {
                out.append(build(segStart, opp, true, false))
            }
            prev = opp
        }
    }

    // MARK: - Pure-Arithmetic Emergency Breaks, Partial Fit & Dynamic Tabs

    private enum PartialFitResult {
        case fits(tot: Double, vis: Double, metrics: LineFontMetrics)
        case trailingSpaceBreak(vis: Double, metrics: LineFontMetrics)
        case emergencyBreak(end: Int, visW: Double, metrics: LineFontMetrics, hitHardBreak: Bool)
    }

    /// End offset of visible content in `start..<end`, stripping trailing line
    /// breaks, space separators, TABs, and zero-width ignorables (like soft
    /// hyphen `U+00AD` or word joiner `U+2060`) that `CTLineGetTrailingWhitespaceWidth`
    /// skips over.
    @inline(__always)
    private static func visibleEnd(in units: [UInt16], from start: Int, to end: Int) -> Int {
        var v = end
        while v > start {
            let u = units[v - 1]
            if FontWidthTable.isTrailingWhitespace(u) || TextLayoutEngine.endsLine(u)
                || FontWidthTable.isTrailingIgnorable(u)
            {
                v -= 1
            } else {
                break
            }
        }
        return v
    }

    /// Computes dynamic tab-stop advances for a segment in a paragraph that
    /// contains `\t` (`0x09`). Runs only on paragraphs with literal tabs.
    private static func measureSegmentWithTabs(
        para: Paragraph, from start: Int, to end: Int, startX: Double,
        units: [UInt16], allRuns: [StyledRun]
    ) -> (tot: Double, vis: Double) {
        guard let icW = para.inContextUnitWidths else { return (0, 0) }
        let visEnd = visibleEnd(in: units, from: start, to: end)
        let pStart = para.range.lowerBound
        var rIdx = para.runSlice.lowerBound
        var x = startX
        var visX = startX
        for i in start..<end {
            let u = units[i]
            if TextLayoutEngine.endsLine(u) { continue }
            if u == 0x09 {
                let globalI = pStart + i
                while rIdx + 1 < para.runSlice.upperBound, globalI >= allRuns[rIdx].range.upperBound { rIdx += 1 }
                x = FontWidthTable.coreTextTabStop(after: x, tabInterval: allRuns[rIdx].tabInterval)
            } else {
                x += Double(icW[i])
            }
            if i < visEnd { visX = x }
        }
        return (x - startX, visX - startX)
    }

    /// Single-pass O(line) partial-segment fitter after an emergency break.
    /// Stops as soon as width exceeds `maxWidth` so arbitrarily long unspaced
    /// tokens (e.g., 256 KB minified JSON/base64) wrap in strict O(N) time.
    private static func fitPartialSegment(
        para: Paragraph, from start: Int, to end: Int, maxWidth: Double,
        isHardBreak: Bool, hasTrailingSpace: Bool,
        units: [UInt16], ns: NSString, allRuns: [StyledRun]
    ) -> PartialFitResult {
        let visEnd = visibleEnd(in: units, from: start, to: end)
        let pStart = para.range.lowerBound
        let pLen = para.range.count

        if para.isPureASCII && para.runSlice.count == 1 {
            let tbl = FontWidthTable.table(for: allRuns[para.runSlice.lowerBound].font)
            let wBuf = tbl.asciiWidths
            let kBuf = tbl.asciiKern
            let hasKern = tbl.hasASCIIKerning
            var tot: Double = 0
            var vis: Double = 0
            var i = start
            while i < end {
                let u = Int(units[i])
                if u == 0x0A {
                    return .fits(tot: tot, vis: vis, metrics: para.defaultMetrics)
                }
                var w = Double(wBuf[u])
                if hasKern && i + 1 < pLen {
                    let nu = Int(units[i + 1])
                    if nu != 0x0A && nu < 128 { w += Double(kBuf[u * 128 + nu]) }
                }
                if tot + w > maxWidth {
                    if i >= visEnd && (hasTrailingSpace || isHardBreak) && vis <= maxWidth {
                        return .trailingSpaceBreak(vis: vis, metrics: para.defaultMetrics)
                    }
                    if i > start {
                        if u == 0x20 || u == 0x09 {
                            var e = i
                            while e < end && (units[e] == 0x20 || units[e] == 0x09) { e += 1 }
                            return .emergencyBreak(end: e, visW: vis, metrics: para.defaultMetrics, hitHardBreak: false)
                        }
                        return .emergencyBreak(end: i, visW: vis, metrics: para.defaultMetrics, hitHardBreak: false)
                    }
                    // Single character wider than `maxWidth`: consume 1 char.
                    return .emergencyBreak(end: i + 1, visW: w, metrics: para.defaultMetrics, hitHardBreak: false)
                }
                tot += w
                if i < visEnd { vis = tot }
                i += 1
            }
            return .fits(tot: tot, vis: vis, metrics: para.defaultMetrics)
        }

        if let icW = para.inContextUnitWidths, let icM = para.inContextUnitMetrics {
            var tot: Double = 0
            var vis: Double = 0
            var m = LineFontMetrics.zero
            var rIdx = para.runSlice.lowerBound
            var i = start
            while i < end {
                if TextLayoutEngine.endsLine(units[i]) {
                    m.formMax(icM[i])
                    let breakEnd = (units[i] == 0x0D && i + 1 < end && units[i + 1] == 0x0A) ? i + 2 : i + 1
                    if breakEnd >= end {
                        return .fits(tot: tot, vis: vis, metrics: m)
                    }
                    return .emergencyBreak(end: breakEnd, visW: vis, metrics: m, hitHardBreak: true)
                }
                let r = TextLayoutEngine.clusterRange(in: ns, at: pStart + i)
                let cEnd = min(end, max(i + 1, NSMaxRange(r) - pStart))
                var cw: Double = 0
                var cm = LineFontMetrics.zero
                var x = tot
                for j in i..<cEnd {
                    cm.formMax(icM[j])
                    let uj = units[j]
                    if TextLayoutEngine.endsLine(uj) { continue }
                    if uj == 0x09 {
                        let globalJ = pStart + j
                        while rIdx + 1 < para.runSlice.upperBound, globalJ >= allRuns[rIdx].range.upperBound {
                            rIdx += 1
                        }
                        x = FontWidthTable.coreTextTabStop(after: x, tabInterval: allRuns[rIdx].tabInterval)
                    } else {
                        x += Double(icW[j])
                    }
                }
                cw = x - tot
                if tot + cw > maxWidth {
                    if i >= visEnd && (hasTrailingSpace || isHardBreak) && vis <= maxWidth {
                        for j in i..<end { m.formMax(icM[j]) }
                        return .trailingSpaceBreak(vis: vis, metrics: m)
                    }
                    if i > start {
                        if FontWidthTable.isTrailingWhitespace(units[i]) {
                            var e = i
                            while e < end && FontWidthTable.isTrailingWhitespace(units[e]) {
                                m.formMax(icM[e])
                                e += 1
                            }
                            return .emergencyBreak(end: e, visW: vis, metrics: m, hitHardBreak: false)
                        }
                        return .emergencyBreak(end: i, visW: vis, metrics: m, hitHardBreak: false)
                    }
                    m.formMax(cm)
                    return .emergencyBreak(
                        end: cEnd, visW: i < visEnd ? cw : 0, metrics: m, hitHardBreak: false)
                }
                tot += cw
                m.formMax(cm)
                if !FontWidthTable.isTrailingWhitespace(units[i]) && !FontWidthTable.isTrailingIgnorable(units[i]) {
                    vis = tot
                }
                i = cEnd
            }
            return .fits(tot: tot, vis: vis, metrics: m)
        }

        // General multi-run / verified non-ASCII path with early exit at `maxWidth`.
        var m = LineFontMetrics.zero
        var tot: Double = 0
        var vis: Double = 0
        var rIdx = para.runSlice.lowerBound
        var i = start
        while i < end {
            let globalI = pStart + i
            while rIdx + 1 < para.runSlice.upperBound, globalI >= allRuns[rIdx].range.upperBound { rIdx += 1 }
            let run = allRuns[rIdx]
            let tbl = FontWidthTable.table(for: run.font)
            let u = units[i]
            if u == 0x0A {
                m.formMax(tbl.baseMetrics)
                return .fits(tot: tot, vis: vis, metrics: m)
            }
            let cEnd: Int
            let cw: Double
            let cm: LineFontMetrics
            if u < 0x80 {
                cEnd = i + 1
                var w = Double(tbl.asciiWidths[Int(u)])
                if globalI + 1 < run.range.upperBound && cEnd < pLen {
                    let nu = units[cEnd]
                    if nu < 0x80 && nu != 0x0A && tbl.hasASCIIKerning {
                        w += Double(tbl.asciiKern[Int(u) * 128 + Int(nu)])
                    }
                }
                cw = w
                cm = tbl.baseMetrics
            } else {
                let r = TextLayoutEngine.clusterRange(in: ns, at: globalI)
                cEnd = min(end, max(i + 1, min(NSMaxRange(r), run.range.upperBound) - pStart))
                let s = ns.substring(with: NSRange(location: globalI, length: cEnd - i))
                let (aw, am) = tbl.nonASCIICluster(s)
                cw = Double(aw)
                cm = am
            }
            if tot + cw > maxWidth {
                if i >= visEnd && (hasTrailingSpace || isHardBreak) && vis <= maxWidth {
                    m.formMax(cm)
                    return .trailingSpaceBreak(vis: vis, metrics: m)
                }
                if i > start {
                    if FontWidthTable.isTrailingWhitespace(u) {
                        var e = i
                        while e < end && FontWidthTable.isTrailingWhitespace(units[e]) { e += 1 }
                        return .emergencyBreak(end: e, visW: vis, metrics: m, hitHardBreak: false)
                    }
                    return .emergencyBreak(end: i, visW: vis, metrics: m, hitHardBreak: false)
                }
                m.formMax(cm)
                return .emergencyBreak(end: cEnd, visW: i < visEnd ? cw : 0, metrics: m, hitHardBreak: false)
            }
            tot += cw
            m.formMax(cm)
            if !FontWidthTable.isTrailingWhitespace(u) && !FontWidthTable.isTrailingIgnorable(u) { vis = tot }
            i = cEnd
        }
        return .fits(tot: tot, vis: vis, metrics: m)
    }

    /// Bounded context-preserving Core Text break for an unspaced BiDi/Arabic
    /// token wider than `maxWidth`, where mid-word Arabic shaping & GPOS
    /// kerning change glyph advances at the split point. Includes up to 64
    /// preceding units so word-joining and hyphen rules match the paragraph.
    private static func ctBiDiLineBreak(
        para: Paragraph, from start: Int, maxWidth: Double, bidiIsRTL: Bool,
        units: [UInt16], ns: NSString, allRuns: [StyledRun]
    ) -> (end: Int, visW: Double, metrics: LineFontMetrics, hitHardBreak: Bool) {
        let pStart = para.range.lowerBound
        let pLen = para.range.count
        var ctxStart = max(0, start - 64)
        for k in stride(from: start - 1, through: ctxStart, by: -1) where TextLayoutEngine.endsLine(units[k]) {
            ctxStart = k + 1
            break
        }
        while ctxStart < start && units[ctxStart] >= 0xDC00 && units[ctxStart] <= 0xDFFF {
            ctxStart += 1
        }
        var windowEnd = min(pLen, start + 1_024)
        for k in start..<windowEnd where TextLayoutEngine.endsLine(units[k]) {
            windowEnd = (units[k] == 0x0D && k + 1 < pLen && units[k + 1] == 0x0A) ? k + 2 : k + 1
            break
        }
        if windowEnd < pLen && windowEnd > start && units[windowEnd - 1] >= 0xD800 && units[windowEnd - 1] <= 0xDBFF {
            windowEnd += 1
        }
        let subAttr = StyledText.attributedSlice(
            of: ns, range: (pStart + ctxStart)..<(pStart + windowEnd), runs: allRuns,
            baseWritingDirection: bidiIsRTL ? .rightToLeft : .leftToRight)
        let typesetter = CTTypesetterCreateWithAttributedString(subAttr)
        let localStart = start - ctxStart
        let count = max(1, min(CTTypesetterSuggestLineBreak(typesetter, localStart, maxWidth), windowEnd - start))
        let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: localStart, length: count))
        let visW = max(
            0,
            CTLineGetTypographicBounds(ctLine, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(ctLine))
        var metrics = LineFontMetrics.zero
        for run in (CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []) {
            var ra: CGFloat = 0
            var rd: CGFloat = 0
            var rl: CGFloat = 0
            _ = CTRunGetTypographicBounds(run, CFRange(), &ra, &rd, &rl)
            metrics.formMax(LineFontMetrics(ascent: Float(ra), descent: Float(rd), leading: Float(rl)))
        }
        if metrics.isZero { metrics = para.defaultMetrics }
        let end = start + count
        let hitHard = end > start && TextLayoutEngine.endsLine(units[end - 1])
        return (end, visW, metrics, hitHard)
    }

    private static func arithmeticEmergencyBreak(
        para: Paragraph, from start: Int, limit: Int, maxWidth: Double,
        units: [UInt16], ns: NSString, allRuns: [StyledRun]
    ) -> (end: Int, visW: Double, metrics: LineFontMetrics, hitHardBreak: Bool) {
        let pStart = para.range.lowerBound
        let pLen = para.range.count
        if para.isPureASCII && para.runSlice.count == 1 {
            let tbl = FontWidthTable.table(for: allRuns[para.runSlice.lowerBound].font)
            let wBuf = tbl.asciiWidths
            let kBuf = tbl.asciiKern
            let hasKern = tbl.hasASCIIKerning
            var tot: Double = 0
            var vis: Double = 0
            var i = start
            while i < limit {
                let u = Int(units[i])
                if u == 0x0A { return (i + 1, vis, para.defaultMetrics, true) }
                var w = Double(wBuf[u])
                if hasKern && i + 1 < pLen {
                    let nu = Int(units[i + 1])
                    if nu != 0x0A && nu < 128 { w += Double(kBuf[u * 128 + nu]) }
                }
                if tot + w > maxWidth && i > start {
                    if u == 0x20 || u == 0x09 {
                        var e = i
                        while e < limit && (units[e] == 0x20 || units[e] == 0x09) { e += 1 }
                        return (e, vis, para.defaultMetrics, false)
                    }
                    return (i, vis, para.defaultMetrics, false)
                }
                tot += w
                if u != 0x20 && u != 0x09 { vis = tot }
                i += 1
            }
            return (max(start + 1, i), vis, para.defaultMetrics, false)
        }
        if let icW = para.inContextUnitWidths, let icM = para.inContextUnitMetrics {
            var tot: Double = 0
            var vis: Double = 0
            var m = LineFontMetrics.zero
            var rIdx = para.runSlice.lowerBound
            var i = start
            while i < limit {
                if TextLayoutEngine.endsLine(units[i]) {
                    m.formMax(icM[i])
                    let breakEnd = (units[i] == 0x0D && i + 1 < limit && units[i + 1] == 0x0A) ? i + 2 : i + 1
                    return (breakEnd, vis, m, true)
                }
                let r = TextLayoutEngine.clusterRange(in: ns, at: pStart + i)
                let cEnd = min(limit, max(i + 1, NSMaxRange(r) - pStart))
                var x = tot
                var cm = LineFontMetrics.zero
                for j in i..<cEnd {
                    cm.formMax(icM[j])
                    let uj = units[j]
                    if TextLayoutEngine.endsLine(uj) { continue }
                    if uj == 0x09 {
                        let globalJ = pStart + j
                        while rIdx + 1 < para.runSlice.upperBound, globalJ >= allRuns[rIdx].range.upperBound {
                            rIdx += 1
                        }
                        x = FontWidthTable.coreTextTabStop(after: x, tabInterval: allRuns[rIdx].tabInterval)
                    } else {
                        x += Double(icW[j])
                    }
                }
                let cw = x - tot
                if tot + cw > maxWidth && i > start {
                    if FontWidthTable.isTrailingWhitespace(units[i]) {
                        var e = i
                        while e < limit && FontWidthTable.isTrailingWhitespace(units[e]) {
                            m.formMax(icM[e])
                            e += 1
                        }
                        return (e, vis, m, false)
                    }
                    return (i, vis, m, false)
                }
                tot += cw
                m.formMax(cm)
                if !FontWidthTable.isTrailingWhitespace(units[i]) && !FontWidthTable.isTrailingIgnorable(units[i]) {
                    vis = tot
                }
                i = cEnd
            }
            return (max(start + 1, i), vis, m, false)
        }
        var m = LineFontMetrics.zero
        var tot: Double = 0
        var vis: Double = 0
        var rIdx = para.runSlice.lowerBound
        var i = start
        while i < limit {
            let globalI = pStart + i
            while rIdx + 1 < para.runSlice.upperBound, globalI >= allRuns[rIdx].range.upperBound { rIdx += 1 }
            let run = allRuns[rIdx]
            let tbl = FontWidthTable.table(for: run.font)
            let u = units[i]
            if u == 0x0A { m.formMax(tbl.baseMetrics); return (i + 1, vis, m, true) }
            let cEnd: Int
            let cw: Double
            let cm: LineFontMetrics
            if u < 0x80 {
                cEnd = i + 1
                var w = Double(tbl.asciiWidths[Int(u)])
                if globalI + 1 < run.range.upperBound && cEnd < pLen {
                    let nu = units[cEnd]
                    if nu < 0x80 && nu != 0x0A && tbl.hasASCIIKerning {
                        w += Double(tbl.asciiKern[Int(u) * 128 + Int(nu)])
                    }
                }
                cw = w
                cm = tbl.baseMetrics
            } else {
                let r = TextLayoutEngine.clusterRange(in: ns, at: globalI)
                cEnd = min(limit, max(i + 1, min(NSMaxRange(r), run.range.upperBound) - pStart))
                let s = ns.substring(with: NSRange(location: globalI, length: cEnd - i))
                let (aw, am) = tbl.nonASCIICluster(s)
                cw = Double(aw)
                cm = am
            }
            if tot + cw > maxWidth && i > start {
                if FontWidthTable.isTrailingWhitespace(u) {
                    var e = i
                    while e < limit && FontWidthTable.isTrailingWhitespace(units[e]) { e += 1 }
                    return (e, vis, m, false)
                }
                return (i, vis, m, false)
            }
            tot += cw
            m.formMax(cm)
            if !FontWidthTable.isTrailingWhitespace(u) && !FontWidthTable.isTrailingIgnorable(u) { vis = tot }
            i = cEnd
        }
        return (max(start + 1, i), vis, m, false)
    }

    // MARK: - Code Non-ASCII Measurement

    private static func measureNonASCIICodeLine(
        code: String, byteRange: Range<Int>, table: FontWidthTable, tabInterval: CGFloat, needsInContext: Bool
    ) -> (width: CGFloat, hasBiDi: Bool) {
        guard !byteRange.isEmpty else { return (0, false) }
        let utf8 = code.utf8
        let sIdx = utf8.index(utf8.startIndex, offsetBy: byteRange.lowerBound)
        let eIdx = utf8.index(utf8.startIndex, offsetBy: byteRange.upperBound)
        let lineString = String(code[sIdx..<eIdx])

        if !needsInContext {
            let ns = lineString as NSString
            let n = ns.length
            let fallbackAdv = max(1, CGFloat(table.asciiWidths[0x30]))
            var x: CGFloat = 0
            var visX: CGFloat = 0
            var i = 0
            while i < n {
                let u = ns.character(at: i)
                if u == 0x09 {
                    x = FontWidthTable.nextTabX(after: x, tabInterval: tabInterval, fallbackAdvance: fallbackAdv)
                    i += 1
                } else if u < 0x80 {
                    x += CGFloat(table.asciiWidths[Int(u)])
                    if u != 0x20 { visX = x }
                    i += 1
                } else {
                    let r = ns.rangeOfComposedCharacterSequence(at: i)
                    let cluster = ns.substring(with: r)
                    x += CGFloat(table.nonASCIICluster(cluster).width)
                    visX = x
                    i = NSMaxRange(r)
                }
            }
            return (visX, false)
        }

        // Exact Core Text measurement for lines with Arabic/Hebrew/Thai/combining/control chars.
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let paraKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)
        var attrs: [NSAttributedString.Key: Any] = [fontKey: table.font]
        if tabInterval > 0 { attrs[paraKey] = StyledText.tabParagraphStyle(interval: tabInterval) }
        let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: lineString, attributes: attrs))
        let total = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        let trailing = CGFloat(CTLineGetTrailingWhitespaceWidth(ctLine))
        var hasBiDi = false
        for run in (CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? [])
        where !CTRunGetStatus(run).isDisjoint(with: [.rightToLeft, .nonMonotonic]) {
            hasBiDi = true
            break
        }
        return (max(0, total - trailing), hasBiDi)
    }

    // MARK: - Helpers

    private static func sameStyledParagraph(_ a: StyledParagraph, _ b: StyledParagraph) -> Bool {
        a.start == b.start && a.firstLineIndent == b.firstLineIndent && a.headIndent == b.headIndent
            && a.spacingBefore == b.spacingBefore && a.quoteBars == b.quoteBars && a.isRule == b.isRule
            && a.taskMarker?.x == b.taskMarker?.x && a.taskMarker?.checked == b.taskMarker?.checked
    }

    private static func sameRuns(
        _ a: [StyledRun], _ aRange: Range<Int>, _ b: [StyledRun], _ bRange: Range<Int>
    ) -> Bool {
        guard aRange.count == bRange.count else { return false }
        for (i, j) in zip(aRange, bRange) where a[i] != b[j] { return false }
        return true
    }

    private static func sameTextSlice(_ a: String, _ b: String, utf16Range: Range<Int>) -> Bool {
        let aUTF16 = a.utf16
        let bUTF16 = b.utf16
        guard utf16Range.upperBound <= aUTF16.count, utf16Range.upperBound <= bUTF16.count else { return false }
        let aLo = aUTF16.index(aUTF16.startIndex, offsetBy: utf16Range.lowerBound)
        let aHi = aUTF16.index(aLo, offsetBy: utf16Range.count)
        let bLo = bUTF16.index(bUTF16.startIndex, offsetBy: utf16Range.lowerBound)
        let bHi = bUTF16.index(bLo, offsetBy: utf16Range.count)
        return a[aLo..<aHi] == b[bLo..<bHi]
    }

    private static func paragraphBytes(_ p: Paragraph) -> Int {
        p.segments.count * MemoryLayout<PreparedSegment>.stride
            + (p.inContextUnitWidths?.count ?? 0) * 4
            + (p.inContextUnitMetrics?.count ?? 0) * 12
            + 96
    }
}
