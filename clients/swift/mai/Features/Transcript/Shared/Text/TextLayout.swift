import CoreGraphics
import CoreText
import Foundation
import Synchronization

/// On-demand shaped line geometry cached only for lines that have been queried
/// for hit testing, carets, selection rects, or links (`REDESIGN.md §4, §9`).
nonisolated struct ShapedLineInfo: Sendable {
    struct Run: Sendable {
        let range: Range<Int>
        let linkIndex: Int?
        let isRightToLeft: Bool
        let visualWidth: CGFloat
    }

    let caretOffsets: [CGFloat]
    let runs: [Run]
    let hasComplexBiDi: Bool
}

/// Unified virtual text layout for all transcript text — prose, headings,
/// lists, quotes, user bubbles, thoughts, notices, table cells, and code
/// blocks (`REDESIGN.md §4, §7 R2`).
///
/// Holds width-independent `PreparedText` + fitted `[TextLine]` (~64 B/line).
/// Core Text shapes and draws strictly the visible lines; carets and run ranges
/// are computed on demand and held in a tiny bounded cache (max 64 lines).
nonisolated struct TextLayout: Sendable {
    private final class ShapedLineCache: Sendable {
        struct State {
            var entries: [Int: ShapedLineInfo] = [:]
            var order: [Int] = []
        }

        static let maxCachedLines = 64
        let state = Mutex<State>(State())

        func info(for lineIndex: Int) -> ShapedLineInfo? {
            state.withLock { $0.entries[lineIndex] }
        }

        func insert(_ info: ShapedLineInfo, for lineIndex: Int) {
            state.withLock { state in
                if state.entries[lineIndex] == nil {
                    state.order.append(lineIndex)
                }
                state.entries[lineIndex] = info
                while state.order.count > Self.maxCachedLines {
                    let oldest = state.order.removeFirst()
                    state.entries.removeValue(forKey: oldest)
                }
            }
        }
    }

    let prepared: PreparedText
    let availableWidth: CGFloat
    let size: CGSize
    let lines: [TextLine]
    let hasComplexBiDi: Bool
    private let shapedCache = ShapedLineCache()

    init(
        prepared: PreparedText,
        availableWidth: CGFloat,
        size: CGSize,
        lines: [TextLine],
        hasComplexBiDi: Bool = false
    ) {
        self.prepared = prepared
        self.availableWidth = availableWidth
        self.size = size
        self.lines = lines
        self.hasComplexBiDi = hasComplexBiDi
    }

    /// The drawn text, for copy and selection offsets (UTF-16).
    var string: String { prepared.text }
    var links: [URL] { prepared.links }

    /// Memory held by this layout: prepared segments + fitted line geometry.
    var retainedBytes: Int {
        prepared.retainedBytes + lines.count * MemoryLayout<TextLine>.stride
    }

    static let empty = TextLayout(prepared: .empty, availableWidth: 0, size: .zero, lines: [])

    /// Re-breaks this layout at `width` using pure arithmetic over the already-
    /// prepared segments (`REDESIGN.md §4.2`: ~0.01 ms normal, ~1.8 ms for 4.65 MB).
    func resized(toWidth width: CGFloat) -> TextLayout {
        if width == availableWidth { return self }
        if !prepared.options.wraps {
            return TextLayout(
                prepared: prepared, availableWidth: width, size: size, lines: lines,
                hasComplexBiDi: hasComplexBiDi)
        }
        return prepared.fit(width: width)
    }

    /// The lines overlapping `minY..<maxY`, for drawing one band.
    func lines(overlapping minY: CGFloat, _ maxY: CGFloat) -> ArraySlice<TextLine> {
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].bottom <= minY { low = middle + 1 } else { high = middle }
        }
        var end = low
        while end < lines.count, lines[end].top < maxY { end += 1 }
        return lines[low..<end]
    }

    /// Index range of lines overlapping `minY..<maxY`.
    func lineIndices(overlapping minY: CGFloat, _ maxY: CGFloat) -> Range<Int> {
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].bottom <= minY { low = middle + 1 } else { high = middle }
        }
        var end = low
        while end < lines.count, lines[end].top < maxY { end += 1 }
        return low..<end
    }

    /// On-demand shaped line geometry (carets and run bounds) for line `index`.
    func shapedLine(at index: Int) -> ShapedLineInfo {
        if let cached = shapedCache.info(for: index) { return cached }
        let line = lines[index]
        let ns = prepared.text as NSString
        let baseDir: CTWritingDirection? =
            if prepared.paragraphs.indices.contains(line.paragraphIndex),
                prepared.paragraphs[line.paragraphIndex].hasBiDiUnits
            {
                line.bidiIsRTL ? .rightToLeft : .leftToRight
            } else {
                nil
            }
        let attr = StyledText.attributedSlice(
            of: ns, range: line.range, runs: prepared.runs, includeStyleIndex: true,
            baseWritingDirection: baseDir)
        let ctLine = CTLineCreateWithAttributedString(attr)
        let localRange = 0..<line.range.count
        let lineNS = attr.string as NSString
        let ctRuns = CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []
        let lineComplexBiDi = ctRuns.contains(where: TextLayoutEngine.needsCoreTextCarets)
        let carets = TextLayoutEngine.caretOffsets(
            of: ctLine, range: localRange, string: lineNS, indent: line.x, width: line.width)
        var runInfos: [ShapedLineInfo.Run] = []
        runInfos.reserveCapacity(ctRuns.count)
        for run in ctRuns {
            guard CTRunGetGlyphCount(run) > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let styleIdx = (attrs[StyledText.styleKey.rawValue] as? NSNumber)?.intValue
            let linkIdx = styleIdx.flatMap { prepared.runs.indices.contains($0) ? prepared.runs[$0].style.linkIndex : nil }
            let sr = CTRunGetStringRange(run)
            let isRTL = lineComplexBiDi && CTRunGetStatus(run).contains(.rightToLeft)
            let visW: CGFloat =
                (lineComplexBiDi || linkIdx != nil)
                ? CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil)) : 0
            runInfos.append(
                ShapedLineInfo.Run(
                    range: (line.range.lowerBound + sr.location)..<(line.range.lowerBound + sr.location + sr.length),
                    linkIndex: linkIdx,
                    isRightToLeft: isRTL,
                    visualWidth: visW))
        }
        let info = ShapedLineInfo(caretOffsets: carets, runs: runInfos, hasComplexBiDi: lineComplexBiDi)
        shapedCache.insert(info, for: index)
        return info
    }

    /// Caret x positions for line `index` (convenience wrapper over `shapedLine(at:)`).
    func caretOffsets(forLineAt index: Int) -> [CGFloat] {
        let line = lines[index]
        if let byteRange = line.fastASCIIByteRange, !line.hasTabs,
            let adv = prepared.codeFontTable?.uniformASCIIAdvance, adv > 0
        {
            let contentCount = byteRange.count
            var offsets = [CGFloat](repeating: 0, count: line.range.count + 1)
            for i in 0...contentCount {
                offsets[i] = line.x + CGFloat(i) * adv
            }
            let endX = line.x + CGFloat(contentCount) * adv
            if contentCount + 1 <= line.range.count {
                for i in (contentCount + 1)...line.range.count { offsets[i] = endX }
            }
            return offsets
        }
        return shapedLine(at: index).caretOffsets
    }

    /// Decorations for `line` at `index` (computed on demand — used by tests
    /// and when verifying decoration parity).
    func decorations(forLineAt index: Int) -> [TextDecoration] {
        let line = lines[index]
        var result: [TextDecoration] = []
        if prepared.hasParagraphDecorations, prepared.paragraphs.indices.contains(line.paragraphIndex) {
            let para = prepared.paragraphs[line.paragraphIndex].styled
            let prevBars: [CGFloat] =
                if index > 0, prepared.paragraphs.indices.contains(lines[index - 1].paragraphIndex) {
                    prepared.paragraphs[lines[index - 1].paragraphIndex].styled.quoteBars
                } else {
                    []
                }
            for bar in para.quoteBars {
                let joinsAbove = prevBars.contains(bar)
                result.append(
                    TextDecoration(
                        kind: .quoteBar,
                        rect: CGRect(
                            x: bar, y: line.top - (joinsAbove ? line.gapAbove : 0),
                            width: prepared.options.quoteBarWidth,
                            height: line.height + (joinsAbove ? line.gapAbove : 0))))
            }
            if line.isParagraphStart, let task = para.taskMarker {
                let boxSize = min(14, max(11, (line.height * 0.68).rounded()))
                let boxY = line.top + ((line.height - boxSize) / 2).rounded()
                result.append(
                    TextDecoration(
                        kind: task.checked ? .taskChecked : .taskUnchecked,
                        rect: CGRect(x: task.x, y: boxY, width: boxSize, height: boxSize)))
            }
            if para.isRule {
                result.append(
                    TextDecoration(
                        kind: .rule,
                        rect: CGRect(
                            x: para.firstLineIndent, y: (line.top + line.height / 2).rounded(.down),
                            width: max(0, availableWidth - para.firstLineIndent), height: 1)))
            }
        }
        if line.hasInlineDecorations {
            let ns = prepared.text as NSString
            let attr = StyledText.attributedSlice(
                of: ns, range: line.range, runs: prepared.runs, includeStyleIndex: true)
            let ctLine = CTLineCreateWithAttributedString(attr)
            TextRenderer.appendInlineDecorations(
                of: ctLine, runs: prepared.runs, lineX: line.x, baseline: line.baseline, into: &result)
        }
        return result
    }

    /// All decorations across the layout (computed lazily for small layouts / tests).
    var decorations: [TextDecoration] {
        guard prepared.hasParagraphDecorations || lines.contains(where: \.hasInlineDecorations) else { return [] }
        var all: [TextDecoration] = []
        for idx in lines.indices {
            all.append(contentsOf: decorations(forLineAt: idx))
        }
        return all
    }
}
