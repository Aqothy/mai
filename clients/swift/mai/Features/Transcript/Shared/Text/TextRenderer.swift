import CoreGraphics
import CoreText
import Foundation

/// Draws only the visible lines of a `TextLayout` via Core Text (`CTLineDraw`,
/// or `CTFontDrawGlyphs` for sliced pure-ASCII monospace code) into a top-down
/// context, on any thread, with pixel parity against AppKit/UIKit rendering.
nonisolated enum TextRenderer {
    static func draw(
        _ layout: TextLayout, at origin: CGPoint, clip: CGRect, palette: TextPalette, in context: CGContext
    ) {
        let local = clip.offsetBy(dx: -origin.x, dy: -origin.y)
        let visibleIndices = layout.lineIndices(overlapping: local.minY, local.maxY)
        guard !visibleIndices.isEmpty else { return }

        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)

        let prepared = layout.prepared
        let ns = prepared.text as NSString
        let hasParaDec = prepared.hasParagraphDecorations
        var fontTables: [(font: CTFont, table: FontWidthTable)] = []
        func tableFor(_ font: CTFont) -> FontWidthTable {
            for entry in fontTables where CFEqual(entry.font, font) { return entry.table }
            let tbl = FontWidthTable.table(for: font)
            fontTables.append((font, tbl))
            return tbl
        }

        for lineIndex in visibleIndices {
            let line = layout.lines[lineIndex]
            let paraModel =
                prepared.paragraphs.indices.contains(line.paragraphIndex)
                ? prepared.paragraphs[line.paragraphIndex] : nil
            let para = paraModel?.styled

            // 1. Paragraph decorations behind text (quote bars, task boxes, thematic rules).
            if hasParaDec, let para {
                drawParagraphDecorations(
                    para, line: line, lineIndex: lineIndex, layout: layout, clip: local, palette: palette, in: context)
            }

            // Thematic rules have `.clear` text; only the hairline rule draws.
            if para?.isRule == true { continue }

            // 2. Ultra-fast horizontal column slice for wide pure-ASCII unwrapped
            //    code lines (draws O(visible columns) even on a 10 MB line).
            if let byteRange = line.fastASCIIByteRange, !byteRange.isEmpty,
                let table = prepared.codeFontTable, table.uniformASCIIAdvance > 0,
                let textColor = palette.color(.primary)
            {
                if drawSlicedASCIICodeLine(
                    text: prepared.text, byteRange: byteRange, hasTabs: line.hasTabs,
                    tabInterval: prepared.codeTabInterval, table: table,
                    lineX: line.x, baseline: line.baseline, clip: local, color: textColor, in: context)
                {
                    continue
                }
            }

            // 3. Direct `CTFontDrawGlyphs` fast path for pure-ASCII non-decorated
            //    prose lines (headings, paragraphs, lists, quotes, bubbles):
            //    avoids per-line `NSAttributedString` + `CTLine` allocation with
            //    0-pixel diff vs `CTLineDraw`.
            if paraModel?.isPureASCII == true, !line.hasInlineDecorations, !line.bidiIsRTL,
                !line.range.isEmpty,
                drawFastASCIIProseLine(
                    ns: ns, line: line, runs: prepared.runs, palette: palette,
                    tableFor: tableFor, in: context)
            {
                continue
            }

            // 4. Standard native Core Text line draw: build attributed slice
            //    only for this single visible line and draw via `CTLineDraw`.
            let baseDir: CTWritingDirection? =
                if let paraModel, paraModel.hasBiDiUnits {
                    line.bidiIsRTL ? .rightToLeft : .leftToRight
                } else {
                    nil
                }
            let attr = StyledText.attributedSlice(
                of: ns, range: line.range, runs: prepared.runs, palette: palette,
                includeStyleIndex: line.hasInlineDecorations, baseWritingDirection: baseDir)
            let ctLine = CTLineCreateWithAttributedString(attr)

            var inlineDecorations: [TextDecoration] = []
            if line.hasInlineDecorations {
                appendInlineDecorations(
                    of: ctLine, runs: prepared.runs, lineX: line.x, baseline: line.baseline, into: &inlineDecorations)
                for dec in inlineDecorations where dec.isBehindText && dec.rect.intersects(local) {
                    drawDecoration(dec, palette: palette, in: context)
                }
            }

            // Draw the line natively in top-down coordinates (0-pixel diff vs CTFontDrawGlyphs).
            // Keep fractional `line.baseline` in `textPosition` rather than the CTM so
            // bitmap emoji (`sbix`) snap identically to bottom-up Core Text rendering.
            context.saveGState()
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: line.x, y: -line.baseline)
            CTLineDraw(ctLine, context)
            context.restoreGState()

            if !inlineDecorations.isEmpty {
                for dec in inlineDecorations where !dec.isBehindText && dec.rect.intersects(local) {
                    drawDecoration(dec, palette: palette, in: context)
                }
            }
        }

        context.restoreGState()
    }

    /// Draws only the visible horizontal slice of a pure-ASCII monospace code
    /// line directly via `CTFontDrawGlyphs` using `FontWidthTable.asciiGlyphs`,
    /// avoiding per-line `String` / `NSAttributedString` / `CTLine` allocation
    /// (5×+ faster code band rastering on iPhone 14 with 0-pixel diff).
    private static func drawSlicedASCIICodeLine(
        text: String, byteRange: Range<Int>, hasTabs: Bool, tabInterval: CGFloat,
        table: FontWidthTable, lineX: CGFloat, baseline: CGFloat,
        clip: CGRect, color: CGColor, in context: CGContext
    ) -> Bool {
        let advance = table.uniformASCIIAdvance
        let margin = max(64, advance * 8)
        let visMinX = clip.minX - lineX - margin
        let visMaxX = clip.maxX - lineX + margin
        guard visMaxX >= 0 else { return true }

        let glyphTable = table.asciiGlyphs
        return text.utf8.withContiguousStorageIfAvailable { storage -> Bool in
            var glyphs: [CGGlyph] = []
            var positions: [CGPoint] = []
            if !hasTabs {
                let len = byteRange.count
                let firstCol = max(0, Int(floor(visMinX / advance)))
                let lastCol = min(len, max(0, Int(ceil(visMaxX / advance))))
                guard firstCol < lastCol else { return true }
                glyphs.reserveCapacity(lastCol - firstCol)
                positions.reserveCapacity(lastCol - firstCol)
                let startByte = byteRange.lowerBound + firstCol
                let endByte = byteRange.lowerBound + lastCol
                var x = lineX + CGFloat(firstCol) * advance
                for idx in startByte..<endByte {
                    let b = Int(storage[idx])
                    if b > 0x20 && b < 0x7F {
                        let g = glyphTable[b]
                        if g != 0 {
                            glyphs.append(g)
                            positions.append(CGPoint(x: x, y: -baseline))
                        }
                    }
                    x += advance
                }
            } else {
                var x: CGFloat = 0
                let end = byteRange.upperBound
                for idx in byteRange.lowerBound..<end {
                    let b = Int(storage[idx])
                    if b == 0x09 {
                        x = FontWidthTable.nextTabX(after: x, tabInterval: tabInterval, fallbackAdvance: advance)
                        if x > visMaxX { break }
                        continue
                    }
                    if x >= visMinX && x <= visMaxX && b > 0x20 && b < 0x7F {
                        let g = glyphTable[b]
                        if g != 0 {
                            glyphs.append(g)
                            positions.append(CGPoint(x: lineX + x, y: -baseline))
                        }
                    }
                    x += advance
                    if x > visMaxX { break }
                }
            }
            guard !glyphs.isEmpty else { return true }
            context.saveGState()
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.setFillColor(color)
            CTFontDrawGlyphs(table.font, glyphs, positions, glyphs.count, context)
            context.restoreGState()
            return true
        } ?? false
    }

    /// Draws a pure-ASCII non-decorated prose line (single- or multi-run)
    /// directly via `CTFontDrawGlyphs` using `FontWidthTable.asciiGlyphs`,
    /// `asciiWidths`, and `asciiKern`. Falls back to `CTLineDraw` if any run
    /// uses a font with ASCII ligatures or contains a contextual ASCII char
    /// adjacent to a digit (e.g. SF Pro `1:2`).
    private static func drawFastASCIIProseLine(
        ns: NSString, line: TextLine, runs: [StyledRun], palette: TextPalette,
        tableFor: (CTFont) -> FontWidthTable, in context: CGContext
    ) -> Bool {
        var lineEnd = line.range.upperBound
        while lineEnd > line.range.lowerBound && ns.character(at: lineEnd - 1) == 0x0A {
            lineEnd -= 1
        }
        let lineStart = line.range.lowerBound
        let len = lineEnd - lineStart
        guard len > 0 else { return true }

        // Binary-search first run intersecting `lineStart..<lineEnd`.
        var lo = 0
        var hi = runs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if runs[mid].range.upperBound <= lineStart { lo = mid + 1 } else { hi = mid }
        }
        guard lo < runs.count else { return false }

        var units = [UInt16](repeating: 0, count: len)
        ns.getCharacters(&units, range: NSRange(location: lineStart, length: len))

        // Collect run slices and validate none require Core Text ligatures or
        // contextual shaping before touching the CGContext.
        struct DrawRun {
            let start: Int
            let end: Int
            let table: FontWidthTable
            let color: CGColor
        }
        var drawRuns: [DrawRun] = []
        var rIdx = lo
        while rIdx < runs.count, runs[rIdx].range.lowerBound < lineEnd {
            let run = runs[rIdx]
            rIdx += 1
            let s = max(lineStart, run.range.lowerBound) - lineStart
            let e = min(lineEnd, run.range.upperBound) - lineStart
            guard s < e else { continue }
            let tbl = tableFor(run.font.font)
            guard !tbl.hasASCIILigatures, let color = palette.color(run.style.color) else { return false }
            let ctxChars = tbl.contextualASCIIChars
            for i in s..<e {
                let u = units[i]
                if u < 0x20 || u >= 0x7F { return false }
                if !ctxChars.isEmpty, ctxChars.contains(u) {
                    let prevDigit = i > s && units[i - 1] >= 0x30 && units[i - 1] <= 0x39
                    let nextDigit = i + 1 < e && units[i + 1] >= 0x30 && units[i + 1] <= 0x39
                    if prevDigit || nextDigit { return false }
                }
            }
            drawRuns.append(DrawRun(start: s, end: e, table: tbl, color: color))
        }
        guard !drawRuns.isEmpty else { return true }

        context.saveGState()
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        var x = line.x
        let negBaseline = -line.baseline
        var glyphs: [CGGlyph] = []
        var positions: [CGPoint] = []
        glyphs.reserveCapacity(len)
        positions.reserveCapacity(len)

        for dr in drawRuns {
            glyphs.removeAll(keepingCapacity: true)
            positions.removeAll(keepingCapacity: true)
            let tbl = dr.table
            let gTable = tbl.asciiGlyphs
            let widths = tbl.asciiWidths
            let kern = tbl.asciiKern
            let hasKern = tbl.hasASCIIKerning
            for i in dr.start..<dr.end {
                let b = Int(units[i])
                if b > 0x20 {
                    let g = gTable[b]
                    if g != 0 {
                        glyphs.append(g)
                        positions.append(CGPoint(x: x, y: negBaseline))
                    }
                }
                var adv = CGFloat(widths[b])
                if hasKern, i + 1 < dr.end {
                    adv += CGFloat(kern[b * 128 + Int(units[i + 1])])
                }
                x += adv
            }
            if !glyphs.isEmpty {
                context.setFillColor(dr.color)
                CTFontDrawGlyphs(tbl.font, glyphs, positions, glyphs.count, context)
            }
        }
        context.restoreGState()
        return true
    }

    static func appendInlineDecorations(
        of ctLine: CTLine, runs: [StyledRun], lineX: CGFloat, baseline: CGFloat, into out: inout [TextDecoration]
    ) {
        let fontKey = kCTFontAttributeName as String
        for run in (CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []) {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let styleIdx = (attrs[StyledText.styleKey.rawValue] as? NSNumber)?.intValue,
                runs.indices.contains(styleIdx)
            else { continue }
            let style = runs[styleIdx].style
            guard style.isInlineCode || style.isUnderlined || style.isStruck else { continue }
            guard let fontValue = attrs[fontKey] as CFTypeRef?, CFGetTypeID(fontValue) == CTFontGetTypeID() else {
                continue
            }
            let ctFont = unsafeDowncast(fontValue, to: CTFont.self)
            var firstPos = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &firstPos)
            let start = lineX + firstPos.x
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let runWidth = CGFloat(
                CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil))
            let thickness = max(1, CTFontGetUnderlineThickness(ctFont))
            if style.isInlineCode {
                out.append(
                    TextDecoration(
                        kind: .inlineCodeBackground,
                        rect: CGRect(
                            x: start - 3, y: baseline - ascent - 1, width: runWidth + 6,
                            height: ascent + descent + 2)))
            }
            if style.isUnderlined {
                out.append(
                    TextDecoration(
                        kind: .underline,
                        rect: CGRect(
                            x: start, y: baseline - CTFontGetUnderlinePosition(ctFont), width: runWidth,
                            height: thickness),
                        color: style.color))
            }
            if style.isStruck {
                out.append(
                    TextDecoration(
                        kind: .strikethrough,
                        rect: CGRect(
                            x: start, y: baseline - CTFontGetXHeight(ctFont) / 2 - thickness / 2, width: runWidth,
                            height: thickness),
                        color: style.color))
            }
        }
    }

    private static func drawParagraphDecorations(
        _ paragraph: StyledParagraph, line: TextLine, lineIndex: Int, layout: TextLayout,
        clip: CGRect, palette: TextPalette, in context: CGContext
    ) {
        if !paragraph.quoteBars.isEmpty {
            let prevBars: [CGFloat] =
                if lineIndex > 0,
                    layout.prepared.paragraphs.indices.contains(layout.lines[lineIndex - 1].paragraphIndex)
                {
                    layout.prepared.paragraphs[layout.lines[lineIndex - 1].paragraphIndex].styled.quoteBars
                } else {
                    []
                }
            let barW = layout.prepared.options.quoteBarWidth
            for bar in paragraph.quoteBars {
                let joinsAbove = prevBars.contains(bar)
                let rect = CGRect(
                    x: bar, y: line.top - (joinsAbove ? line.gapAbove : 0), width: barW,
                    height: line.height + (joinsAbove ? line.gapAbove : 0))
                if rect.intersects(clip) {
                    context.setFillColor(palette.tertiary)
                    context.fill(rect)
                }
            }
        }
        if line.isParagraphStart, let task = paragraph.taskMarker {
            let boxSize = min(14, max(11, (line.height * 0.68).rounded()))
            let boxY = line.top + ((line.height - boxSize) / 2).rounded()
            let rect = CGRect(x: task.x, y: boxY, width: boxSize, height: boxSize)
            if rect.intersects(clip) {
                drawDecoration(
                    TextDecoration(kind: task.checked ? .taskChecked : .taskUnchecked, rect: rect),
                    palette: palette, in: context)
            }
        }
        if paragraph.isRule {
            let rect = CGRect(
                x: paragraph.firstLineIndent, y: (line.top + line.height / 2).rounded(.down),
                width: max(0, layout.availableWidth - paragraph.firstLineIndent), height: 1)
            if rect.intersects(clip) {
                context.setFillColor(palette.separator)
                context.fill(rect)
            }
        }
    }

    private static func drawDecoration(_ decoration: TextDecoration, palette: TextPalette, in context: CGContext) {
        switch decoration.kind {
        case .inlineCodeBackground:
            context.setFillColor(palette.inlineCodeBackground)
            context.addPath(CGPath(roundedRect: decoration.rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.fillPath()
        case .quoteBar:
            context.setFillColor(palette.tertiary)
            context.fill(decoration.rect)
        case .rule:
            context.setFillColor(palette.separator)
            context.fill(decoration.rect)
        case .taskUnchecked:
            let box = decoration.rect.insetBy(dx: 0.75, dy: 0.75)
            context.setStrokeColor(palette.secondary)
            context.setLineWidth(1.25)
            context.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.strokePath()
        case .taskChecked:
            let box = decoration.rect.insetBy(dx: 0.75, dy: 0.75)
            let boxPath = CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil)
            context.setFillColor(palette.inlineCodeBackground)
            context.addPath(boxPath)
            context.fillPath()
            context.setStrokeColor(palette.primary)
            context.setLineWidth(1.25)
            context.addPath(boxPath)
            context.strokePath()
            context.setLineWidth(1.6)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            let r = decoration.rect
            context.beginPath()
            context.move(to: CGPoint(x: r.minX + r.width * 0.25, y: r.minY + r.height * 0.52))
            context.addLine(to: CGPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.70))
            context.addLine(to: CGPoint(x: r.minX + r.width * 0.75, y: r.minY + r.height * 0.30))
            context.strokePath()
        case .underline, .strikethrough:
            guard let color = decoration.color.flatMap(palette.color) else { return }
            context.setFillColor(color)
            context.fill(decoration.rect)
        }
    }
}
