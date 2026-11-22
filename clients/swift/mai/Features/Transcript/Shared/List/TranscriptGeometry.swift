import CoreGraphics
import Foundation

/// Every row's height, estimated or measured, and where each row starts.
/// Heights live in a Fenwick tree, so a row's offset, the row at a y and a
/// height change are O(log n): streaming growth and measuring near the
/// viewport stay cheap in a chat of thousands of rows. Structural changes
/// (rows added, removed or reordered) rebuild it in O(n).
///
/// Heights are whole points (rows are laid out to whole points), so sums are
/// exact and two ways of computing an offset never disagree.
nonisolated struct TranscriptGeometry {
    private(set) var ids: [String] = []
    /// The content each row shows. The rows one piece of content is split
    /// into share it: a reply's blocks all show the same message.
    private(set) var sources: [String] = []
    private(set) var heights: [CGFloat] = []
    private(set) var totalHeight: CGFloat = 0
    /// 1-based Fenwick tree over `heights`.
    private var tree: [CGFloat] = [0]
    private var indices: [String: Int] = [:]
    private var sourceStarts: [String: Int] = [:]

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    func height(at index: Int) -> CGFloat { heights[index] }
    func index(for id: String) -> Int? { indices[id] }

    /// Replaces the rows. A row that stays keeps its height; a new one takes
    /// `estimate(index)` (an index into the new rows). IDs should be unique;
    /// a duplicate resolves to its first row instead of trapping.
    mutating func replace(
        ids: [String], sources: [String], measured: [String: CGFloat] = [:],
        estimate: (Int) -> CGFloat
    ) {
        let previous = indices
        let oldHeights = heights
        self.ids = ids
        self.sources = sources.count == ids.count ? sources : ids
        heights = []
        heights.reserveCapacity(ids.count)
        for (index, id) in ids.enumerated() {
            if let height = measured[id], height.isFinite {
                heights.append(Self.clamped(height))
            } else if let old = previous[id] {
                heights.append(oldHeights[old])
            } else {
                heights.append(Self.clamped(estimate(index)))
            }
        }
        rebuildIndex()
        rebuildTree()
    }

    /// Replaces the rows in `range` with new ones, in O(rows after
    /// `range.lowerBound` × log n): a streamed message gaining a block near
    /// the end touches only the rows from there on.
    mutating func replaceRows(
        _ range: Range<Int>, ids newIDs: [String], sources newSources: [String], heights newHeights: [CGFloat]
    ) {
        let start = range.lowerBound
        let oldEnd = range.upperBound
        let delta = newIDs.count - range.count
        // Forget only the removed rows instead of tearing down and rehashing
        // every unchanged entry in the tail.
        var clearedID = false
        var clearedSource = false
        for index in range {
            if indices[ids[index]] == index {
                indices[ids[index]] = nil
                clearedID = true
            }
            if sourceStarts[sources[index]] == index {
                sourceStarts[sources[index]] = nil
                clearedSource = true
            }
        }
        ids.replaceSubrange(range, with: newIDs)
        sources.replaceSubrange(range, with: newSources)
        heights.replaceSubrange(range, with: newHeights.map(Self.clamped))
        let newEnd = start + newIDs.count
        // Shift/repair surviving tail entries into post-replacement coordinates
        // first so writing `start..<newEnd` cannot collide with unshifted tail
        // indices. Reverse order for `delta > 0` prevents cascading overwrites.
        if delta > 0 {
            for index in (newEnd..<ids.count).reversed() {
                let id = ids[index]
                if let existing = indices[id] {
                    if (existing == index - delta && existing >= oldEnd) || existing > index { indices[id] = index }
                } else {
                    indices[id] = index
                }
                if index == newEnd || sources[index] != sources[index - 1] {
                    let source = sources[index]
                    if let existing = sourceStarts[source] {
                        if (existing == index - delta && existing >= oldEnd) || existing > index {
                            sourceStarts[source] = index
                        }
                    } else {
                        sourceStarts[source] = index
                    }
                }
            }
        } else if delta < 0 || clearedID || clearedSource {
            for index in newEnd..<ids.count {
                if delta < 0 || clearedID {
                    let id = ids[index]
                    if let existing = indices[id] {
                        if delta < 0, existing == index - delta, existing >= oldEnd { indices[id] = index }
                    } else {
                        indices[id] = index
                    }
                }
                if delta < 0 || clearedSource, index == newEnd || sources[index] != sources[index - 1] {
                    let source = sources[index]
                    if let existing = sourceStarts[source] {
                        if delta < 0, existing == index - delta, existing >= oldEnd { sourceStarts[source] = index }
                    } else {
                        sourceStarts[source] = index
                    }
                }
            }
        }
        // Prefix entries are `< start` and tail entries are now `>= newEnd`, so
        // forward writes in `start..<newEnd` keep the smallest index per key.
        for index in start..<newEnd {
            let id = ids[index]
            if let existing = indices[id] {
                if existing > index { indices[id] = index }
            } else {
                indices[id] = index
            }
            let source = sources[index]
            if let existing = sourceStarts[source] {
                if existing > index { sourceStarts[source] = index }
            } else {
                sourceStarts[source] = index
            }
        }
        // Nodes before the change cover only rows before it and stay valid.
        tree.removeSubrange((start + 1)...)
        let base = prefix(start)
        var running = base
        var prefixes: [CGFloat] = []
        prefixes.reserveCapacity(ids.count - start)
        for index in start..<ids.count {
            running += heights[index]
            prefixes.append(running)
            let node = index + 1
            let from = node - (node & -node)
            let before = from >= start ? (from == start ? base : prefixes[from - start - 1]) : prefix(from)
            tree.append(running - before)
        }
        totalHeight = running
    }

    /// Measured heights by row ID; unknown IDs and non-finite values are
    /// ignored.
    mutating func setHeights(_ updates: [String: CGFloat]) {
        for (id, height) in updates {
            guard height.isFinite, let index = indices[id] else { continue }
            setHeight(height, at: index)
        }
    }

    private mutating func setHeight(_ height: CGFloat, at index: Int) {
        let height = Self.clamped(height)
        let delta = height - heights[index]
        guard delta != 0 else { return }
        heights[index] = height
        totalHeight += delta
        var node = index + 1
        while node < tree.count {
            tree[node] += delta
            node += node & -node
        }
    }

    /// Where row `index` starts; `count` gives the end of the last row.
    func offset(at index: Int) -> CGFloat { prefix(index) }

    func frame(at index: Int) -> (minY: CGFloat, height: CGFloat) {
        (prefix(index), heights[index])
    }

    /// The row containing `y`, rows being half-open intervals; positions
    /// before the first row or past the last clamp to them. Nil without rows.
    func index(at y: CGFloat) -> Int? {
        guard !ids.isEmpty else { return nil }
        var position = 0
        var remaining = y
        var step = 1
        while step * 2 <= ids.count { step *= 2 }
        while step > 0 {
            let next = position + step
            if next <= ids.count, tree[next] <= remaining {
                position = next
                remaining -= tree[next]
            }
            step /= 2
        }
        return min(position, ids.count - 1)
    }

    /// The rows overlapping `minY..<maxY`.
    func indices(overlapping minY: CGFloat, _ maxY: CGFloat) -> ClosedRange<Int>? {
        guard let first = index(at: minY), let last = index(at: max(minY, maxY - 0.001)) else {
            return nil
        }
        return first...max(first, last)
    }

    // MARK: Reading place

    /// The place of a reader whose viewport top is at `top`.
    func readingPlace(atViewportTop top: CGFloat) -> ReadingPlace? {
        guard let index = index(at: max(0, top)) else { return nil }
        let rowTop = prefix(index)
        let source = sources[index]
        let sourceStart = sourceStarts[source] ?? index
        return ReadingPlace(
            anchorID: ids[index], offsetIntoRow: top - rowTop, source: source,
            offsetIntoSource: rowTop - prefix(sourceStart) + top - rowTop,
            idsAbove: ids[..<index], sourcesAbove: sources[..<index])
    }

    /// Where a place taken before the rows changed is now. While its row
    /// stays, that row, its offset clamped to the row's new height. Else the
    /// same distance into the rows now showing its content; else just below
    /// the nearest row above it that stayed. Nil if nothing it knew stayed.
    func offset(for place: ReadingPlace) -> CGFloat? {
        if let index = indices[place.anchorID] {
            return prefix(index) + min(place.offsetIntoRow, heights[index])
        }
        if let start = sourceStarts[place.source] {
            let startY = prefix(start)
            return startY + min(place.offsetIntoSource, sourceEnd(from: start) - startY)
        }
        for index in place.idsAbove.indices.reversed() {
            if let kept = indices[place.idsAbove[index]] { return prefix(kept + 1) }
            if let start = sourceStarts[place.sourcesAbove[index]] { return sourceEnd(from: start) }
        }
        return nil
    }

    /// Where a saved place from an earlier session of this thread is now.
    /// Matches by row ID first, then by source ID (for example a message still
    /// represented as `.pendingMessage` before initial parse). Nil if neither
    /// exists in the loaded rows.
    func offset(for saved: TranscriptSavedPlace) -> CGFloat? {
        if let index = indices[saved.anchorID] {
            return prefix(index) + min(saved.offsetIntoRow, heights[index])
        }
        if let start = sourceStarts[saved.source] {
            let startY = prefix(start)
            // Stay strictly inside the source so an under-estimated `.pendingMessage`
            // still overlaps the initial viewport and gets parsed before reveal.
            let span = sourceEnd(from: start) - startY
            return startY + min(saved.offsetIntoSource, max(0, span - 1))
        }
        return nil
    }

    // MARK: Internals

    /// Rows are at least a point tall, so every row has a place to anchor.
    private static func clamped(_ height: CGFloat) -> CGFloat {
        height.isFinite ? max(1, height) : 1
    }

    private func prefix(_ count: Int) -> CGFloat {
        var node = min(count, ids.count)
        var sum: CGFloat = 0
        while node > 0 {
            sum += tree[node]
            node -= node & -node
        }
        return sum
    }

    /// The bottom of the run of rows showing the source of row `start`.
    private func sourceEnd(from start: Int) -> CGFloat {
        var end = start + 1
        while end < sources.count, sources[end] == sources[start] { end += 1 }
        return prefix(end)
    }

    private mutating func rebuildIndex() {
        indices = Dictionary(
            ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        sourceStarts = Dictionary(
            sources.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    private mutating func rebuildTree() {
        tree = [0] + heights
        for node in 1..<max(1, tree.count) {
            let parent = node + (node & -node)
            if parent < tree.count { tree[parent] += tree[node] }
        }
        totalHeight = heights.reduce(0, +)
    }
}
