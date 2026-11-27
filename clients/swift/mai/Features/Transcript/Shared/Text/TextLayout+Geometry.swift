import CoreGraphics
import Foundation

/// Hit testing, carets, selection rects, and links over the unified virtual
/// `TextLayout` (`REDESIGN.md §4, §9`). Pure-ASCII monospace lines answer in
/// O(1) arithmetic; proportional and non-ASCII lines query only the single
/// touched line's cached `ShapedLineInfo`.
nonisolated extension TextLayout {
    /// The UTF-16 length of the text: lines cover it end to end.
    var length: Int { prepared.length }

    /// The line at `y`, or the nearest one above or below the text. A point in
    /// the gap between two lines snaps to the closer line by vertical midpoint
    /// (YYText rule).
    func lineIndex(nearestY y: CGFloat) -> Int? {
        guard !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].bottom <= y { low = middle + 1 } else { high = middle }
        }
        if low >= lines.count { return lines.count - 1 }
        if low > 0, y < lines[low].top {
            let midpoint = (lines[low - 1].bottom + lines[low].top) / 2
            return y < midpoint ? low - 1 : low
        }
        return low
    }

    /// Binary search for the line containing UTF-16 `offset`.
    func lineIndex(forUTF16Offset offset: Int) -> Int? {
        guard !lines.isEmpty else { return nil }
        let clamped = min(max(0, offset), length)
        var low = 0
        var high = lines.count
        while low + 1 < high {
            let mid = (low + high) / 2
            if lines[mid].range.lowerBound <= clamped { low = mid } else { high = mid }
        }
        return low
    }

    /// The caret offset closest to `point` (layout coordinates).
    func offset(closestTo point: CGPoint) -> Int {
        guard let index = lineIndex(nearestY: point.y) else { return 0 }
        if point.y < 0 { return 0 }
        if point.y >= size.height, index == lines.count - 1 { return length }
        let line = lines[index]

        // O(1) arithmetic path for pure-ASCII unwrapped code lines (handles
        // 10 MB single horizontal lines without shaping).
        if let byteRange = line.fastASCIIByteRange,
            let table = prepared.codeFontTable, table.uniformASCIIAdvance > 0
        {
            let contentLen = byteRange.count
            guard contentLen > 0 else { return line.range.lowerBound }
            let localOffset: Int
            if !line.hasTabs {
                let dx = point.x - line.x
                localOffset = dx <= 0 ? 0 : min(contentLen, Int((dx / table.uniformASCIIAdvance).rounded()))
            } else {
                let targetX = point.x - line.x
                let adv = table.uniformASCIIAdvance
                let tab = prepared.codeTabInterval
                localOffset =
                    prepared.text.utf8.withContiguousStorageIfAvailable { storage -> Int in
                        var curX: CGFloat = 0
                        for idx in byteRange {
                            let b = storage[idx]
                            let nextX =
                                b == 0x09
                                ? FontWidthTable.nextTabX(after: curX, tabInterval: tab, fallbackAdvance: adv)
                                : curX + adv
                            if targetX < (curX + nextX) / 2 { return idx - byteRange.lowerBound }
                            curX = nextX
                        }
                        return contentLen
                    } ?? contentLen
            }
            return line.range.lowerBound + min(localOffset, contentLen)
        }

        let shaped = shapedLine(at: index)
        let carets = shaped.caretOffsets
        let best: Int
        if !shaped.hasComplexBiDi, !carets.isEmpty {
            var low = 0
            var high = carets.count
            while low < high {
                let mid = (low + high) / 2
                if carets[mid] < point.x { low = mid + 1 } else { high = mid }
            }
            if low == 0 {
                best = 0
            } else if low >= carets.count {
                var idx = carets.count - 1
                while idx > 0, carets[idx - 1] == carets[idx] { idx -= 1 }
                best = idx
            } else {
                let rightDist = abs(carets[low] - point.x)
                let leftDist = abs(carets[low - 1] - point.x)
                var idx = leftDist <= rightDist ? low - 1 : low
                while idx > 0, carets[idx - 1] == carets[idx] { idx -= 1 }
                best = idx
            }
        } else {
            var chosen = 0
            var distance = CGFloat.infinity
            for (position, x) in carets.enumerated() where abs(x - point.x) < distance {
                distance = abs(x - point.x)
                chosen = position
            }
            best = chosen
        }
        let offset = line.range.lowerBound + best
        if offset == line.range.upperBound, line.endsWithNewline { return offset - 1 }
        return offset
    }

    /// Caret x for UTF-16 `localOffset` inside line `index`.
    func caretX(forLocalOffset localOffset: Int, inLineAt index: Int) -> CGFloat {
        let line = lines[index]
        if let byteRange = line.fastASCIIByteRange,
            let table = prepared.codeFontTable, table.uniformASCIIAdvance > 0
        {
            let clamped = min(max(0, localOffset), byteRange.count)
            if !line.hasTabs {
                return line.x + CGFloat(clamped) * table.uniformASCIIAdvance
            }
            let adv = table.uniformASCIIAdvance
            let tab = prepared.codeTabInterval
            if let fastX = prepared.text.utf8.withContiguousStorageIfAvailable({ storage -> CGFloat in
                let target = min(byteRange.upperBound, byteRange.lowerBound + clamped)
                var x: CGFloat = 0
                for idx in byteRange.lowerBound..<target {
                    x =
                        storage[idx] == 0x09
                        ? FontWidthTable.nextTabX(after: x, tabInterval: tab, fallbackAdvance: adv) : x + adv
                }
                return line.x + x
            }) {
                return fastX
            }
        }
        let carets = shapedLine(at: index).caretOffsets
        guard !carets.isEmpty else { return line.x }
        return carets[min(max(0, localOffset), carets.count - 1)]
    }

    /// Caret rect in layout coordinates for UTF-16 `utf16Offset`.
    func caretRect(for utf16Offset: Int) -> CGRect? {
        guard let index = lineIndex(forUTF16Offset: utf16Offset) else { return nil }
        let line = lines[index]
        let clamped = min(max(0, utf16Offset), length)
        let local = clamped - line.range.lowerBound
        let x = caretX(forLocalOffset: local, inLineAt: index)
        return CGRect(x: x, y: line.top, width: 2, height: line.height)
    }

    /// Highlight rects for `range`, one per line it touches (layout
    /// coordinates). For giant selections spanning > 512 lines, emits exact
    /// first/last line rects and one solid interior block.
    func selectionRects(for range: Range<Int>) -> [CGRect] {
        guard !range.isEmpty, !lines.isEmpty else { return [] }
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].range.upperBound <= range.lowerBound { low = mid + 1 } else { high = mid }
        }
        guard low < lines.count, lines[low].range.lowerBound < range.upperBound else { return [] }

        var last = low
        var endHigh = lines.count
        while last + 1 < endHigh {
            let mid = (last + endHigh) / 2
            if lines[mid].range.lowerBound < range.upperBound { last = mid } else { endHigh = mid }
        }

        if last - low > 512 {
            var rects: [CGRect] = []
            rects.append(contentsOf: singleLineSelectionRects(at: low, range: range))
            let midTop = lines[low + 1].top
            let midBottom = lines[last].top
            if midBottom > midTop {
                rects.append(
                    CGRect(x: 0, y: midTop, width: max(size.width, lines[low].height / 3), height: midBottom - midTop))
            }
            rects.append(contentsOf: singleLineSelectionRects(at: last, range: range))
            return rects
        }

        var rects: [CGRect] = []
        rects.reserveCapacity(last - low + 1)
        for index in low...last {
            rects.append(contentsOf: singleLineSelectionRects(at: index, range: range))
        }
        return rects
    }

    private func singleLineSelectionRects(at index: Int, range: Range<Int>) -> [CGRect] {
        let line = lines[index]
        guard line.range.lowerBound < range.upperBound, line.range.upperBound > range.lowerBound else { return [] }
        let from = max(range.lowerBound, line.range.lowerBound) - line.range.lowerBound
        let to = min(range.upperBound, line.range.upperBound) - line.range.lowerBound
        var bottom = line.bottom
        if index + 1 < lines.count, lines[index + 1].top - line.bottom <= 4 {
            bottom = lines[index + 1].top
        }

        // O(1) full-line fast path: avoids shaping/CTLineEnumerateCaretOffsets
        // for every fully-selected line during Select All and multi-line drags.
        if from == 0 && to >= line.range.count {
            var width = max(0, line.width)
            if line.endsWithNewline && range.upperBound >= line.range.upperBound {
                width += line.height / 3
            }
            return [CGRect(x: line.x, y: line.top, width: width, height: bottom - line.top)]
        }

        // Fast O(1) pure-ASCII code line path.
        if let byteRange = line.fastASCIIByteRange,
            let table = prepared.codeFontTable, table.uniformASCIIAdvance > 0
        {
            let contentLen = byteRange.count
            let x0 = caretX(forLocalOffset: min(from, contentLen), inLineAt: index)
            var x1 = caretX(forLocalOffset: min(to, contentLen), inLineAt: index)
            if line.endsWithNewline, range.upperBound >= line.range.upperBound {
                x1 += line.height / 3
            }
            return [CGRect(x: min(x0, x1), y: line.top, width: max(0, abs(x1 - x0)), height: bottom - line.top)]
        }

        let shaped = shapedLine(at: index)
        if shaped.hasComplexBiDi {
            let selStart = max(range.lowerBound, line.range.lowerBound)
            let selEnd = min(range.upperBound, line.range.upperBound)
            var lineRects: [CGRect] = []
            var runLeft = line.x
            for run in shaped.runs {
                let runRight = runLeft + run.visualWidth
                defer { runLeft = runRight }
                let lo = max(selStart, run.range.lowerBound)
                let hi = min(selEnd, run.range.upperBound)
                guard lo < hi else { continue }
                let loX: CGFloat
                let hiX: CGFloat
                if lo == run.range.lowerBound {
                    loX = run.isRightToLeft ? runRight : runLeft
                } else {
                    loX = shaped.caretOffsets[lo - line.range.lowerBound]
                }
                if hi == run.range.upperBound {
                    hiX = run.isRightToLeft ? runLeft : runRight
                } else {
                    hiX = shaped.caretOffsets[hi - line.range.lowerBound]
                }
                let minX = min(loX, hiX)
                let maxX = max(loX, hiX)
                guard maxX > minX else { continue }
                let rect = CGRect(x: minX, y: line.top, width: maxX - minX, height: bottom - line.top)
                if let last = lineRects.last, rect.minX <= last.maxX + 0.5 && rect.maxX >= last.minX - 0.5 {
                    lineRects[lineRects.count - 1] = last.union(rect)
                } else {
                    lineRects.append(rect)
                }
            }
            if !lineRects.isEmpty {
                if line.endsWithNewline, range.upperBound >= line.range.upperBound {
                    lineRects[lineRects.count - 1].size.width += line.height / 3
                }
                return lineRects
            }
        }

        let carets = shaped.caretOffsets
        var minX = min(carets[min(from, carets.count - 1)], carets[min(to, carets.count - 1)])
        var maxX = max(carets[min(from, carets.count - 1)], carets[min(to, carets.count - 1)])
        if line.endsWithNewline, range.upperBound >= line.range.upperBound {
            maxX += line.height / 3
        }
        if from == 0 { minX = min(minX, line.x) }
        return [CGRect(x: minX, y: line.top, width: max(0, maxX - minX), height: bottom - line.top)]
    }

    /// The link drawn at `point` (layout coordinates), if any.
    func link(at point: CGPoint) -> URL? {
        guard !links.isEmpty, let index = lineIndex(nearestY: point.y) else { return nil }
        let line = lines[index]
        guard line.hasInlineDecorations, point.y >= line.top, point.y < line.bottom else { return nil }
        let shaped = shapedLine(at: index)
        var runLeft = line.x
        for run in shaped.runs {
            let runRight = runLeft + run.visualWidth
            defer { runLeft = runRight }
            guard let link = run.linkIndex, links.indices.contains(link) else { continue }
            let minX: CGFloat
            let maxX: CGFloat
            if shaped.hasComplexBiDi {
                minX = runLeft
                maxX = runRight
            } else {
                let from = run.range.lowerBound - line.range.lowerBound
                let to = run.range.upperBound - line.range.lowerBound
                guard shaped.caretOffsets.indices.contains(from), shaped.caretOffsets.indices.contains(to) else {
                    continue
                }
                minX = min(shaped.caretOffsets[from], shaped.caretOffsets[to])
                maxX = max(shaped.caretOffsets[from], shaped.caretOffsets[to])
            }
            if point.x >= minX, point.x < maxX { return links[link] }
        }
        return nil
    }
}
