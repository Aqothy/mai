import CoreGraphics
import Foundation

/// Hit testing and selection rects from the layout's values alone (PLAN
/// 3.3): binary searches over lines and the caret offsets Core Text
/// reported at layout time, no Core Text objects.
nonisolated extension TextLayout {
    /// The UTF-16 length of the text: lines cover it end to end.
    var length: Int { lines.last?.range.upperBound ?? 0 }

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

    /// The caret offset closest to `point` (layout coordinates).
    func offset(closestTo point: CGPoint) -> Int {
        guard let index = lineIndex(nearestY: point.y) else { return 0 }
        if point.y < 0 { return 0 }
        if point.y >= size.height, index == lines.count - 1 { return length }
        let line = lines[index]
        let best: Int
        if !line.hasComplexBiDi, !line.caretOffsets.isEmpty {
            let carets = line.caretOffsets
            var low = 0
            var high = carets.count
            while low < high {
                let mid = (low + high) / 2
                if carets[mid] < point.x { low = mid + 1 } else { high = mid }
            }
            if low == 0 {
                best = 0
            } else if low >= carets.count {
                // Keep the earliest index sharing the final caret position
                // (e.g. inside a trailing cluster/emoji).
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
            for (position, x) in line.caretOffsets.enumerated() where abs(x - point.x) < distance {
                distance = abs(x - point.x)
                chosen = position
            }
            best = chosen
        }
        let offset = line.range.lowerBound + best
        // Past a hard break's end the caret stays before the newline; after
        // it is the next line's start.
        if offset == line.range.upperBound, line.endsWithNewline { return offset - 1 }
        return offset
    }

    /// Highlight rects for `range`, one per line it touches (layout
    /// coordinates). A line's rect reaches down to the next line's top when
    /// only line spacing separates them, so a highlight reads as one block.
    func selectionRects(for range: Range<Int>) -> [CGRect] {
        guard !range.isEmpty, !lines.isEmpty else { return [] }
        // Binary search for the first line overlapping `range.lowerBound`.
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].range.upperBound <= range.lowerBound { low = mid + 1 } else { high = mid }
        }
        var rects: [CGRect] = []
        for index in low..<lines.count {
            let line = lines[index]
            if line.range.lowerBound >= range.upperBound { break }
            let from = max(range.lowerBound, line.range.lowerBound) - line.range.lowerBound
            let to = min(range.upperBound, line.range.upperBound) - line.range.lowerBound
            var bottom = line.bottom
            if index + 1 < lines.count, lines[index + 1].top - line.bottom <= 4 { bottom = lines[index + 1].top }
            if line.hasComplexBiDi {
                let selStart = max(range.lowerBound, line.range.lowerBound)
                let selEnd = min(range.upperBound, line.range.upperBound)
                var lineRects: [CGRect] = []
                var runLeft = line.x
                for runIndex in line.runs {
                    let run = runs[runIndex]
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
                        loX = line.caretOffsets[lo - line.range.lowerBound]
                    }
                    if hi == run.range.upperBound {
                        hiX = run.isRightToLeft ? runLeft : runRight
                    } else {
                        hiX = line.caretOffsets[hi - line.range.lowerBound]
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
                    rects.append(contentsOf: lineRects)
                    continue
                }
            }
            var minX = min(line.caretOffsets[from], line.caretOffsets[to])
            var maxX = max(line.caretOffsets[from], line.caretOffsets[to])
            // A selected newline shows as a little space past the line.
            if line.endsWithNewline, range.upperBound >= line.range.upperBound { maxX += line.height / 3 }
            if from == 0 { minX = min(minX, line.x) }
            rects.append(CGRect(x: minX, y: line.top, width: max(0, maxX - minX), height: bottom - line.top))
        }
        return rects
    }

    /// The link drawn at `point` (layout coordinates), if any.
    func link(at point: CGPoint) -> URL? {
        guard !links.isEmpty, let index = lineIndex(nearestY: point.y) else { return nil }
        let line = lines[index]
        guard point.y >= line.top, point.y < line.bottom else { return nil }
        var runLeft = line.x
        for runIndex in line.runs {
            let run = runs[runIndex]
            let runRight = runLeft + run.visualWidth
            defer { runLeft = runRight }
            guard let link = run.linkIndex, links.indices.contains(link) else { continue }
            let minX: CGFloat
            let maxX: CGFloat
            if line.hasComplexBiDi {
                minX = runLeft
                maxX = runRight
            } else {
                let from = run.range.lowerBound - line.range.lowerBound
                let to = run.range.upperBound - line.range.lowerBound
                guard line.caretOffsets.indices.contains(from), line.caretOffsets.indices.contains(to) else { continue }
                minX = min(line.caretOffsets[from], line.caretOffsets[to])
                maxX = max(line.caretOffsets[from], line.caretOffsets[to])
            }
            if point.x >= minX, point.x < maxX { return links[link] }
        }
        return nil
    }
}
