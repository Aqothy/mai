import CoreGraphics
import CoreText
import Foundation
import Synchronization

/// Cached printable-ASCII glyph & advance table for a monospace `CTFont`
/// (SF Mono), eliminating `NSAttributedString` and `CTTypesetter` overhead
/// for ASCII code lines (8–13× faster, 0.00 pt visual difference).
nonisolated struct MonospaceASCIIMetrics: Sendable {
    let font: TranscriptFont
    /// Glyph IDs for ASCII 0..<128 (`0` outside printable `0x20...0x7E`).
    let glyphs: [CGGlyph]
    let advance: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let isUniform: Bool

    private static let cache = Mutex<[CGFloat: MonospaceASCIIMetrics]>([:])

    static func metrics(for font: TranscriptFont) -> MonospaceASCIIMetrics {
        let size = CTFontGetSize(font.font)
        if let cached = cache.withLock({ $0[size] }), CFEqual(cached.font.font, font.font) {
            return cached
        }
        var chars = [UniChar](0x20...0x7E)
        var rawGlyphs = [CGGlyph](repeating: 0, count: chars.count)
        let mapped = CTFontGetGlyphsForCharacters(font.font, &chars, &rawGlyphs, chars.count)
        var advances = [CGSize](repeating: .zero, count: chars.count)
        CTFontGetAdvancesForGlyphs(font.font, .horizontal, &rawGlyphs, &advances, chars.count)
        let advance = advances.first?.width ?? 0
        var uniform = mapped && advance > 0
        var fullGlyphs = [CGGlyph](repeating: 0, count: 128)
        for index in 0..<chars.count {
            fullGlyphs[0x20 + index] = rawGlyphs[index]
            if abs(advances[index].width - advance) > 0.01 { uniform = false }
        }
        let result = MonospaceASCIIMetrics(
            font: font, glyphs: fullGlyphs, advance: advance,
            ascent: CTFontGetAscent(font.font), descent: CTFontGetDescent(font.font),
            isUniform: uniform)
        cache.withLock { $0[size] = result }
        return result
    }

    @inline(__always)
    static func isFastASCIIByte(_ byte: UInt8) -> Bool {
        (byte >= 0x20 && byte <= 0x7E) || byte == 0x09
    }

    @inline(__always)
    func nextTabX(after x: CGFloat, tabInterval: CGFloat) -> CGFloat {
        guard tabInterval > 0 else { return x + advance }
        return (floor((x + 0.001) / tabInterval) + 1) * tabInterval
    }

    @inline(__always)
    func baselineOffset(fixedLineHeight: CGFloat) -> CGFloat {
        (fixedLineHeight - ascent - descent) / 2 + ascent
    }

    /// Materializes a pure-ASCII code block into a `TextLayout` without
    /// touching `NSAttributedString` or `CTTypesetter`. Returns `nil` if any
    /// byte requires Core Text shaping (non-ASCII, control chars, or syntax colors).
    func materializeASCII(code: String, style: TextStyle) -> TextLayout? {
        guard isUniform else { return nil }
        guard !code.isEmpty else { return .empty }
        return code.utf8.withContiguousStorageIfAvailable { bytes -> TextLayout? in
            materializeASCII(bytes: bytes, code: code, style: style)
        } ?? materializeASCII(bytes: Array(code.utf8), code: code, style: style)
    }

    private func materializeASCII<C: RandomAccessCollection>(
        bytes: C, code: String, style: TextStyle
    ) -> TextLayout? where C.Element == UInt8, C.Index == Int {
        // Verify pure fast ASCII + `\n` before allocating layout arrays.
        for byte in bytes where byte != 0x0A && !Self.isFastASCIIByte(byte) {
            return nil
        }
        let count = bytes.count
        let lineHeight = style.codeLineHeight
        let tabInterval = style.codeTabInterval
        let baselineShift = baselineOffset(fixedLineHeight: lineHeight)

        var lines: [TextLine] = []
        var runs: [TextGlyphRun] = []
        var maxWidth: CGFloat = 0
        var y: CGFloat = 0
        var lineStart = 0

        while lineStart < count {
            var lineEnd = lineStart
            while lineEnd < count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            let endsWithNewline = lineEnd < count
            let rangeEnd = endsWithNewline ? lineEnd + 1 : lineEnd
            let lineLen = rangeEnd - lineStart

            let baseline = y + baselineShift
            var carets = [CGFloat](repeating: 0, count: lineLen + 1)
            var lineGlyphs: [CGGlyph] = []
            var linePositions: [CGPoint] = []
            lineGlyphs.reserveCapacity(lineEnd - lineStart)
            linePositions.reserveCapacity(lineEnd - lineStart)

            var x: CGFloat = 0
            var visibleWidth: CGFloat = 0
            for idx in lineStart..<lineEnd {
                let byte = bytes[idx]
                carets[idx - lineStart] = x
                if byte == 0x09 {
                    x = nextTabX(after: x, tabInterval: tabInterval)
                } else {
                    if byte != 0x20 {
                        lineGlyphs.append(glyphs[Int(byte)])
                        linePositions.append(CGPoint(x: x, y: -baseline))
                        visibleWidth = x + advance
                    }
                    x += advance
                }
            }
            carets[lineEnd - lineStart] = x
            if endsWithNewline { carets[lineLen] = x }

            let firstRun = runs.count
            if !lineGlyphs.isEmpty {
                runs.append(
                    TextGlyphRun(
                        font: font, glyphs: lineGlyphs, positions: linePositions, color: .primary,
                        range: lineStart..<lineEnd, linkIndex: nil, isRightToLeft: false, visualWidth: visibleWidth))
            }
            lines.append(
                TextLine(
                    top: y, baseline: baseline, height: lineHeight, x: 0, width: visibleWidth,
                    range: lineStart..<rangeEnd, caretOffsets: carets, runs: firstRun..<runs.count,
                    decorations: 0..<0, endsWithNewline: endsWithNewline, hasComplexBiDi: false))
            maxWidth = max(maxWidth, visibleWidth)
            y += lineHeight
            lineStart = rangeEnd
        }

        return TextLayout(
            string: code, size: CGSize(width: ceil(maxWidth), height: ceil(y)),
            lines: lines, runs: runs, decorations: [], links: [], hasComplexBiDi: false)
    }
}

/// 2D-virtualized storage for extreme code blocks (`> 16 KB` or any single
/// line `> 4 KB`): holds only an O(lineCount) line-start index (~16 bytes/line)
/// and shapes/draws strictly the visible `(lines × columns)` slice per tile.
/// Handles 500,000-line code dumps AND 1 MB+ single horizontal lines in < 2 ms.
nonisolated struct VirtualCodeBody: Sendable {
    let code: String
    /// UTF-8 byte offset of each line start (`lineByteStarts.count == lineCount`).
    let lineByteStarts: [Int]
    /// UTF-16 code-unit offset of each line start (`lineUTF16Starts.count == lineCount`).
    let lineUTF16Starts: [Int]
    /// Line indices containing any non-ASCII or control byte (excluding
    /// trailing `\r` in CRLF). Empty (0 bytes) on pure ASCII dumps so all
    /// ASCII hit-testing, width, caret, selection, and drawing stay consistent.
    let nonASCIILines: Set<Int>
    /// Line indices containing `\t` (empty on tab-free dumps so pure ASCII
    /// lines slice directly to visible columns in O(visible width)).
    let tabbedLines: Set<Int>
    /// True when any non-ASCII line exceeds `CodeLayout.virtualizeLineLimit`,
    /// keeping sync raster fallback off the main thread for giant BiDi/CJK lines.
    let hasLargeNonASCIILine: Bool
    let totalUTF16: Int
    let lineHeight: CGFloat
    let tabInterval: CGFloat
    let ascii: MonospaceASCIIMetrics
    let style: TextStyle
    let colors: CodeColors?
    /// Tight body size (`maxLineWidth × lineCount * lineHeight`), matching `TextLayout.size`.
    let size: CGSize

    var lineCount: Int { lineByteStarts.count }
    var retainedBytes: Int { lineByteStarts.count * 16 + nonASCIILines.count * 16 + tabbedLines.count * 16 + 128 }

    init(code: String, style: TextStyle, colors: CodeColors?, ascii: MonospaceASCIIMetrics) {
        self.code = code
        self.style = style
        self.colors = colors
        self.ascii = ascii
        self.lineHeight = style.codeLineHeight
        self.tabInterval = style.codeTabInterval

        var byteStarts: [Int] = [0]
        var utf16Starts: [Int] = [0]
        var nonASCIILines: Set<Int> = []
        var tabbedLines: Set<Int> = []
        var hasLargeNonASCIILine = false
        var maxLineWidth: CGFloat = 0
        var totalUTF16 = 0
        let advance = ascii.advance
        let tabInterval = style.codeTabInterval

        func scan<C: RandomAccessCollection>(_ bytes: C) where C.Element == UInt8, C.Index == Int {
            let count = bytes.count
            var lineIndex = 0
            var lineByteStart = 0
            var lineHasNonASCII = false
            var lineHasTab = false
            var colX: CGFloat = 0
            var visibleX: CGFloat = 0
            var idx = 0

            func finishLine(at endByte: Int) {
                if lineHasNonASCII {
                    nonASCIILines.insert(lineIndex)
                    if endByte - lineByteStart > CodeLayout.virtualizeLineLimit {
                        hasLargeNonASCIILine = true
                    }
                }
                if lineHasTab { tabbedLines.insert(lineIndex) }
                maxLineWidth = max(maxLineWidth, visibleX)
            }

            while idx < count {
                let b = bytes[idx]
                if b == 0x0A {
                    finishLine(at: idx)
                    totalUTF16 += 1
                    idx += 1
                    if idx < count {
                        lineIndex += 1
                        lineByteStart = idx
                        lineHasNonASCII = false
                        lineHasTab = false
                        byteStarts.append(idx)
                        utf16Starts.append(totalUTF16)
                    }
                    colX = 0
                    visibleX = 0
                } else if b == 0x0D, idx + 1 < count, bytes[idx + 1] == 0x0A {
                    // Trailing `\r` in CRLF contributes a UTF-16 code unit but
                    // zero visual width and stays on the fast ASCII path.
                    totalUTF16 += 1
                    idx += 1
                } else if b < 0x80 {
                    if b == 0x09 {
                        lineHasTab = true
                        colX = ascii.nextTabX(after: colX, tabInterval: tabInterval)
                    } else if b >= 0x20 && b <= 0x7E {
                        colX += advance
                        if b != 0x20 { visibleX = colX }
                    } else {
                        lineHasNonASCII = true
                        colX += advance
                        visibleX = colX
                    }
                    totalUTF16 += 1
                    idx += 1
                } else {
                    lineHasNonASCII = true
                    // Multi-byte UTF-8 lead byte: 4-byte scalars encode as 2 UTF-16 units.
                    let charLen: Int
                    let utf16Len: Int
                    let widthFactor: CGFloat
                    if b < 0xE0 {
                        charLen = 2; utf16Len = 1; widthFactor = 1
                    } else if b < 0xF0 {
                        charLen = 3; utf16Len = 1; widthFactor = 2
                    } else {
                        charLen = 4; utf16Len = 2; widthFactor = 2
                    }
                    colX += advance * widthFactor
                    visibleX = colX
                    totalUTF16 += utf16Len
                    idx = min(count, idx + charLen)
                }
            }
            finishLine(at: count)
        }

        if code.utf8.withContiguousStorageIfAvailable({ scan($0); return true }) == nil {
            scan(Array(code.utf8))
        }

        self.lineByteStarts = byteStarts
        self.lineUTF16Starts = utf16Starts
        self.nonASCIILines = nonASCIILines
        self.tabbedLines = tabbedLines
        self.hasLargeNonASCIILine = hasLargeNonASCIILine
        self.totalUTF16 = totalUTF16
        let height = CGFloat(max(1, byteStarts.count)) * style.codeLineHeight
        self.size = CGSize(width: ceil(maxLineWidth), height: ceil(height))
    }

    /// UTF-8 byte range of line `lineIndex` (excluding trailing `\n` or `\r\n`).
    private func lineContentByteRange(_ lineIndex: Int) -> Range<Int> {
        let start = lineByteStarts[lineIndex]
        let nextStart = lineIndex + 1 < lineByteStarts.count ? lineByteStarts[lineIndex + 1] : code.utf8.count
        var end = nextStart
        if end > start {
            let prev = code.utf8.index(code.utf8.startIndex, offsetBy: end - 1)
            if code.utf8[prev] == 0x0A {
                end -= 1
                if end > start {
                    let beforeLF = code.utf8.index(before: prev)
                    if code.utf8[beforeLF] == 0x0D { end -= 1 }
                }
            }
        }
        return start..<end
    }

    /// Number of trailing line-break UTF-16 units (`2` for `\r\n`, `1` for `\n`, `0` otherwise).
    private func lineTrailingBreakUTF16Count(_ lineIndex: Int) -> Int {
        let start = lineByteStarts[lineIndex]
        let nextStart = lineIndex + 1 < lineByteStarts.count ? lineByteStarts[lineIndex + 1] : code.utf8.count
        guard nextStart > start else { return 0 }
        let lastIdx = code.utf8.index(code.utf8.startIndex, offsetBy: nextStart - 1)
        guard code.utf8[lastIdx] == 0x0A else { return 0 }
        if nextStart - start >= 2, code.utf8[code.utf8.index(before: lastIdx)] == 0x0D {
            return 2
        }
        return 1
    }

    /// Full UTF-16 range of line `lineIndex` (including trailing `\n`/`\r\n` when present).
    func lineUTF16Range(_ lineIndex: Int) -> Range<Int> {
        let start = lineUTF16Starts[lineIndex]
        let end = lineIndex + 1 < lineUTF16Starts.count ? lineUTF16Starts[lineIndex + 1] : totalUTF16
        return start..<end
    }

    func lineEndsWithNewline(_ lineIndex: Int) -> Bool {
        lineTrailingBreakUTF16Count(lineIndex) > 0
    }

    /// Binary search for the line containing UTF-16 `offset`.
    func lineIndex(forUTF16Offset offset: Int) -> Int {
        guard !lineUTF16Starts.isEmpty else { return 0 }
        let clamped = min(max(0, offset), totalUTF16)
        var low = 0
        var high = lineUTF16Starts.count
        while low + 1 < high {
            let mid = (low + high) / 2
            if lineUTF16Starts[mid] <= clamped { low = mid } else { high = mid }
        }
        return low
    }

    /// Draws only the lines overlapping `clip.minY...clip.maxY` and only the
    /// character columns overlapping `clip.minX...clip.maxX`.
    func draw(at origin: CGPoint, clip: CGRect, palette: TextPalette, in context: CGContext) {
        guard !code.isEmpty, lineCount > 0, let textColor = palette.color(.primary) else { return }
        let local = clip.offsetBy(dx: -origin.x, dy: -origin.y)
        let firstLine = max(0, Int(floor(local.minY / lineHeight)))
        let lastLine = min(lineCount - 1, Int(ceil(local.maxY / lineHeight)))
        guard firstLine <= lastLine else { return }

        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let baselineShift = ascii.baselineOffset(fixedLineHeight: lineHeight)
        let advance = ascii.advance
        let margin = max(64, advance * 8)
        let visMinX = local.minX - margin
        let visMaxX = local.maxX + margin

        var glyphBuf: [CGGlyph] = []
        var posBuf: [CGPoint] = []
        glyphBuf.reserveCapacity(256)
        posBuf.reserveCapacity(256)

        for lineIndex in firstLine...lastLine {
            let range = lineContentByteRange(lineIndex)
            guard !range.isEmpty else { continue }
            let y = CGFloat(lineIndex) * lineHeight
            let baseline = y + baselineShift

            let drewFast = drawFastASCIILine(
                lineIndex: lineIndex, byteRange: range, baseline: baseline, visMinX: visMinX, visMaxX: visMaxX,
                textColor: textColor, glyphBuf: &glyphBuf, posBuf: &posBuf, in: context)
            if !drewFast {
                let lineLayout = layoutSingleLine(lineIndex)
                TextRenderer.draw(
                    lineLayout, at: CGPoint(x: 0, y: y), clip: local, palette: palette, in: context)
            }
        }
        context.restoreGState()
    }

    private func drawFastASCIILine(
        lineIndex: Int, byteRange: Range<Int>, baseline: CGFloat, visMinX: CGFloat, visMaxX: CGFloat,
        textColor: CGColor, glyphBuf: inout [CGGlyph], posBuf: inout [CGPoint], in context: CGContext
    ) -> Bool {
        guard ascii.isUniform, colors == nil, !nonASCIILines.contains(lineIndex) else { return false }
        guard visMaxX >= 0 else { return true }
        let utf8 = code.utf8
        return utf8.withContiguousStorageIfAvailable { storage -> Bool in
            let start = byteRange.lowerBound
            let end = byteRange.upperBound
            let len = end - start
            let advance = ascii.advance

            glyphBuf.removeAll(keepingCapacity: true)
            posBuf.removeAll(keepingCapacity: true)

            if !tabbedLines.contains(lineIndex) {
                // Pure printable ASCII with no tabs: jump straight to the
                // visible column slice in O(visible columns) even on 10 MB lines.
                let approxFirst = max(0, Int(floor(visMinX / advance)))
                let approxLast = min(len, max(0, Int(ceil(visMaxX / advance))))
                guard approxFirst < approxLast else { return true }
                for offset in approxFirst..<approxLast {
                    let b = storage[start + offset]
                    if b != 0x20 {
                        glyphBuf.append(ascii.glyphs[Int(b)])
                        posBuf.append(CGPoint(x: CGFloat(offset) * advance, y: -baseline))
                    }
                }
            } else {
                var x: CGFloat = 0
                for idx in start..<end {
                    let b = storage[idx]
                    if b == 0x09 {
                        x = ascii.nextTabX(after: x, tabInterval: tabInterval)
                        if x > visMaxX { break }
                    } else {
                        if x >= visMinX && x <= visMaxX && b != 0x20 {
                            glyphBuf.append(ascii.glyphs[Int(b)])
                            posBuf.append(CGPoint(x: x, y: -baseline))
                        }
                        x += advance
                        if x > visMaxX { break }
                    }
                }
            }

            guard !glyphBuf.isEmpty else { return true }
            context.setFillColor(textColor)
            glyphBuf.withUnsafeBufferPointer { gPtr in
                posBuf.withUnsafeBufferPointer { pPtr in
                    guard let g = gPtr.baseAddress, let p = pPtr.baseAddress else { return }
                    CTFontDrawGlyphs(ascii.font.font, g, p, glyphBuf.count, context)
                }
            }
            return true
        } ?? false
    }

    /// Slices `colors.runs` to the UTF-16 range of `lineIndex` via binary search
    /// (O(log R) per line) so highlighted virtualized code renders syntax colors.
    private func lineColors(for lineIndex: Int, lineString: String) -> CodeColors? {
        guard let colors, !colors.runs.isEmpty else { return nil }
        let lineStart = lineUTF16Starts[lineIndex]
        let lineEnd = lineStart + lineString.utf16.count
        guard lineEnd > lineStart else { return nil }
        let runs = colors.runs
        var low = 0
        var high = runs.count
        while low < high {
            let mid = (low + high) / 2
            if runs[mid].range.upperBound <= lineStart { low = mid + 1 } else { high = mid }
        }
        var sliced: [CodeColors.Run] = []
        var idx = low
        while idx < runs.count, runs[idx].range.lowerBound < lineEnd {
            let run = runs[idx]
            let clampedStart = max(run.range.lowerBound, lineStart)
            let clampedEnd = min(run.range.upperBound, lineEnd)
            if clampedStart < clampedEnd {
                sliced.append(
                    CodeColors.Run(
                        range: (clampedStart - lineStart)..<(clampedEnd - lineStart), color: run.color))
            }
            idx += 1
        }
        return sliced.isEmpty ? nil : CodeColors(code: lineString, runs: sliced, isDark: colors.isDark)
    }

    /// Lays out one single line (on demand, e.g. for highlighted/non-ASCII lines,
    /// hit-testing, or caret queries on virtualized code).
    func layoutSingleLine(_ lineIndex: Int) -> TextLayout {
        let range = lineContentByteRange(lineIndex)
        let utf8 = code.utf8
        let startIdx = utf8.index(utf8.startIndex, offsetBy: range.lowerBound)
        let endIdx = utf8.index(utf8.startIndex, offsetBy: range.upperBound)
        let lineString = String(code[startIdx..<endIdx])
        let slicedColors = lineColors(for: lineIndex, lineString: lineString)
        if slicedColors == nil, !nonASCIILines.contains(lineIndex),
            let fast = ascii.materializeASCII(code: lineString, style: style)
        {
            return fast
        }
        return TextLayoutEngine.layout(
            CodeLayout.buildStyledCode(lineString, colors: slicedColors, style: style),
            width: .greatestFiniteMagnitude,
            options: .init(lineSpacing: 0, wraps: false, fixedLineHeight: lineHeight))
    }

    // MARK: Geometry & selection (O(1) / O(log N))

    func offset(closestTo point: CGPoint) -> Int {
        guard lineCount > 0 else { return 0 }
        if point.y < 0 { return 0 }
        if point.y >= size.height { return totalUTF16 }
        let lineIndex = min(max(0, Int(floor(point.y / lineHeight))), lineCount - 1)
        let utf16Range = lineUTF16Range(lineIndex)
        let contentLen = utf16Range.count - lineTrailingBreakUTF16Count(lineIndex)
        guard contentLen > 0 else { return utf16Range.lowerBound }
        if let asciiOffset = fastASCIIOffset(inLine: lineIndex, x: point.x) {
            return utf16Range.lowerBound + min(asciiOffset, contentLen)
        }
        let lineLayout = layoutSingleLine(lineIndex)
        let localOffset = lineLayout.offset(closestTo: CGPoint(x: point.x, y: lineHeight / 2))
        return utf16Range.lowerBound + min(localOffset, contentLen)
    }

    func strictOffset(at point: CGPoint) -> Int? {
        guard lineCount > 0, point.y >= 0, point.y < size.height, point.x >= 0 else { return nil }
        let lineIndex = min(max(0, Int(floor(point.y / lineHeight))), lineCount - 1)
        let lineWidth = widthOfLine(lineIndex)
        guard point.x <= lineWidth else { return nil }
        return offset(closestTo: point)
    }

    func caretRect(for utf16Offset: Int) -> CGRect {
        let clamped = min(max(0, utf16Offset), totalUTF16)
        let lineIndex = lineIndex(forUTF16Offset: clamped)
        let utf16Range = lineUTF16Range(lineIndex)
        let contentLen = utf16Range.count - lineTrailingBreakUTF16Count(lineIndex)
        let localOffset = min(clamped - utf16Range.lowerBound, contentLen)
        let x = xForOffset(localOffset, inLine: lineIndex)
        return CGRect(x: x, y: CGFloat(lineIndex) * lineHeight, width: 2, height: lineHeight)
    }

    func selectionRects(for range: Range<Int>) -> [CGRect] {
        guard !range.isEmpty, lineCount > 0 else { return [] }
        let startLine = lineIndex(forUTF16Offset: range.lowerBound)
        let endLine = lineIndex(forUTF16Offset: max(range.lowerBound, range.upperBound - 1))

        // For massive multi-thousand-line selections (e.g. Cmd+A on a 500k-line
        // code dump), emit exact first/last lines and one solid interior block
        // so `CAShapeLayer` / `UITextInput` never constructs 500,000 subpaths.
        if endLine - startLine > 512 {
            var rects: [CGRect] = []
            rects.append(contentsOf: singleLineSelectionRects(lineIndex: startLine, range: range))
            let midTop = CGFloat(startLine + 1) * lineHeight
            let midBottom = CGFloat(endLine) * lineHeight
            if midBottom > midTop {
                rects.append(
                    CGRect(x: 0, y: midTop, width: max(size.width, lineHeight / 3), height: midBottom - midTop))
            }
            rects.append(contentsOf: singleLineSelectionRects(lineIndex: endLine, range: range))
            return rects
        }

        var rects: [CGRect] = []
        rects.reserveCapacity(endLine - startLine + 1)
        for lineIndex in startLine...endLine {
            rects.append(contentsOf: singleLineSelectionRects(lineIndex: lineIndex, range: range))
        }
        return rects
    }

    private func singleLineSelectionRects(lineIndex: Int, range: Range<Int>) -> [CGRect] {
        let utf16Range = lineUTF16Range(lineIndex)
        let selStart = max(range.lowerBound, utf16Range.lowerBound)
        let selEnd = min(range.upperBound, utf16Range.upperBound)
        guard selStart < selEnd else { return [] }
        let contentLen = utf16Range.count - lineTrailingBreakUTF16Count(lineIndex)
        let from = min(selStart - utf16Range.lowerBound, contentLen)
        let to = min(selEnd - utf16Range.lowerBound, contentLen)
        if nonASCIILines.contains(lineIndex) {
            let lineLayout = layoutSingleLine(lineIndex)
            let y = CGFloat(lineIndex) * lineHeight
            var rects = (from < to ? lineLayout.selectionRects(for: from..<to) : [])
                .map { $0.offsetBy(dx: 0, dy: y) }
            if lineEndsWithNewline(lineIndex), range.upperBound >= utf16Range.upperBound {
                let tailX = rects.map(\.maxX).max() ?? lineLayout.size.width
                rects.append(CGRect(x: tailX, y: y, width: lineHeight / 3, height: lineHeight))
            }
            return rects
        }
        let x0 = xForOffset(from, inLine: lineIndex)
        var x1 = xForOffset(to, inLine: lineIndex)
        if lineEndsWithNewline(lineIndex), range.upperBound >= utf16Range.upperBound {
            x1 += lineHeight / 3
        }
        return [CGRect(x: min(x0, x1), y: CGFloat(lineIndex) * lineHeight, width: max(0, abs(x1 - x0)), height: lineHeight)]
    }

    private func fastASCIIOffset(inLine lineIndex: Int, x: CGFloat) -> Int? {
        guard ascii.isUniform, !nonASCIILines.contains(lineIndex) else { return nil }
        let range = lineContentByteRange(lineIndex)
        if !tabbedLines.contains(lineIndex) {
            guard x > 0 else { return 0 }
            return min(range.count, Int((x / ascii.advance).rounded()))
        }
        return code.utf8.withContiguousStorageIfAvailable { storage -> Int? in
            var curX: CGFloat = 0
            for idx in range {
                let b = storage[idx]
                let nextX = b == 0x09 ? ascii.nextTabX(after: curX, tabInterval: tabInterval) : curX + ascii.advance
                if x < (curX + nextX) / 2 { return idx - range.lowerBound }
                curX = nextX
            }
            return range.count
        } ?? .none
    }

    private func xForOffset(_ localOffset: Int, inLine lineIndex: Int) -> CGFloat {
        guard localOffset > 0 else { return 0 }
        let range = lineContentByteRange(lineIndex)
        if ascii.isUniform, !nonASCIILines.contains(lineIndex) {
            if !tabbedLines.contains(lineIndex) {
                return CGFloat(min(localOffset, range.count)) * ascii.advance
            }
            if let fastX = code.utf8.withContiguousStorageIfAvailable({ storage -> CGFloat in
                let target = min(range.upperBound, range.lowerBound + localOffset)
                var x: CGFloat = 0
                for idx in range.lowerBound..<target {
                    x = storage[idx] == 0x09 ? ascii.nextTabX(after: x, tabInterval: tabInterval) : x + ascii.advance
                }
                return x
            }) {
                return fastX
            }
        }
        let lineLayout = layoutSingleLine(lineIndex)
        guard let line = lineLayout.lines.first, !line.caretOffsets.isEmpty else { return 0 }
        return line.caretOffsets[min(localOffset, line.caretOffsets.count - 1)]
    }

    private func widthOfLine(_ lineIndex: Int) -> CGFloat {
        let range = lineContentByteRange(lineIndex)
        if ascii.isUniform, !nonASCIILines.contains(lineIndex),
            let fastWidth = code.utf8.withContiguousStorageIfAvailable({ storage -> CGFloat in
                var x: CGFloat = 0
                var visibleX: CGFloat = 0
                for idx in range {
                    let b = storage[idx]
                    if b == 0x09 {
                        x = ascii.nextTabX(after: x, tabInterval: tabInterval)
                    } else {
                        x += ascii.advance
                        if b != 0x20 { visibleX = x }
                    }
                }
                return visibleX
            })
        {
            return fastWidth
        }
        return layoutSingleLine(lineIndex).size.width
    }

    /// Unchanged height from top compared to `other` (streaming optimization).
    func unchangedHeight(comparedTo other: VirtualCodeBody) -> CGFloat {
        guard style.version == other.style.version,
            CFEqual(ascii.font.font, other.ascii.font.font),
            lineHeight == other.lineHeight, tabInterval == other.tabInterval,
            ascii.advance == other.ascii.advance, colors == other.colors
        else { return 0 }
        let shared = min(lineCount, other.lineCount)
        let aUTF8 = code.utf8
        let bUTF8 = other.code.utf8
        for index in 0..<shared {
            let rA = lineContentByteRange(index)
            let rB = other.lineContentByteRange(index)
            if rA.count != rB.count { return CGFloat(index) * lineHeight }
            let aStart = aUTF8.index(aUTF8.startIndex, offsetBy: rA.lowerBound)
            let aEnd = aUTF8.index(aUTF8.startIndex, offsetBy: rA.upperBound)
            let bStart = bUTF8.index(bUTF8.startIndex, offsetBy: rB.lowerBound)
            let bEnd = bUTF8.index(bUTF8.startIndex, offsetBy: rB.upperBound)
            if !aUTF8[aStart..<aEnd].elementsEqual(bUTF8[bStart..<bEnd]) {
                return CGFloat(index) * lineHeight
            }
        }
        if lineCount == other.lineCount { return .infinity }
        return CGFloat(shared) * lineHeight
    }
}
