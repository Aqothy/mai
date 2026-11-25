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
    private struct Edit {
        let at: Int
        let oldEnd: Int
        let delta: Int
    }

    private struct IndexEntry {
        let index: Int
        let epoch: Int
    }

    private static let maxPendingEdits = 64

    /// 1-based Fenwick tree over `heights`.
    private var tree: [CGFloat] = [0]
    private var indices: [String: IndexEntry] = [:]
    private var sourceStarts: [String: IndexEntry] = [:]
    /// Pending structural splices applied on lookup so mid-history splices
    /// (`replaceRows`) never rehash thousands of unchanged tail dictionary entries.
    private var edits: [Edit] = []
    private var hasDuplicateIDs = false
    private var hasNonContiguousSources = false

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    func height(at index: Int) -> CGFloat { heights[index] }

    func index(for id: String) -> Int? {
        guard let entry = indices[id] else { return nil }
        return resolve(entry)
    }

    private func sourceStart(for source: String) -> Int? {
        guard let entry = sourceStarts[source] else { return nil }
        return resolve(entry)
    }

    @inline(__always)
    private func resolve(_ entry: IndexEntry) -> Int? {
        var idx = entry.index
        var epoch = entry.epoch
        let count = edits.count
        while epoch < count {
            let edit = edits[epoch]
            if idx >= edit.oldEnd {
                idx += edit.delta
            } else if idx >= edit.at {
                return nil
            }
            epoch += 1
        }
        return idx
    }

    /// Replaces the rows. A row that stays keeps its height; a new one takes
    /// `estimate(index)` (an index into the new rows). IDs should be unique;
    /// a duplicate resolves to its first row instead of trapping.
    mutating func replace(
        ids: [String], sources: [String], measured: [String: CGFloat] = [:],
        estimate: (Int) -> CGFloat
    ) {
        let oldHeights = heights
        var previous: [String: Int] = [:]
        previous.reserveCapacity(self.ids.count)
        for (id, entry) in indices {
            if let resolved = resolve(entry) { previous[id] = resolved }
        }
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

    /// Replaces the rows in `range` with new ones: records one O(1) shift for
    /// surviving tail entries (compacting once every `maxPendingEdits` splices)
    /// instead of rehashing every row after `range.lowerBound`.
    mutating func replaceRows(
        _ range: Range<Int>, ids newIDs: [String], sources newSources: [String], heights newHeights: [CGFloat]
    ) {
        let start = range.lowerBound
        let oldEnd = range.upperBound
        let delta = newIDs.count - range.count
        let newEnd = start + newIDs.count
        let clampedHeights = newHeights.map(Self.clamped)

        if hasDuplicateIDs || hasNonContiguousSources || edits.count >= Self.maxPendingEdits {
            ids.replaceSubrange(range, with: newIDs)
            sources.replaceSubrange(range, with: newSources)
            heights.replaceSubrange(range, with: clampedHeights)
            rebuildIndex()
            updateTreeAfterReplace(start: start)
            return
        }

        // Remove entries belonging strictly to the replaced slice.
        for index in range {
            indices[ids[index]] = nil
            let source = sources[index]
            if let existing = sourceStart(for: source), range.contains(existing) {
                sourceStarts[source] = nil
            }
        }
        ids.replaceSubrange(range, with: newIDs)
        sources.replaceSubrange(range, with: newSources)
        heights.replaceSubrange(range, with: clampedHeights)

        edits.append(Edit(at: start, oldEnd: oldEnd, delta: delta))
        let epoch = edits.count

        for index in start..<newEnd {
            let id = ids[index]
            if let existing = self.index(for: id) {
                hasDuplicateIDs = true
                if index < existing { indices[id] = IndexEntry(index: index, epoch: epoch) }
            } else {
                indices[id] = IndexEntry(index: index, epoch: epoch)
            }
            let source = sources[index]
            if let existing = sourceStart(for: source) {
                if index < existing {
                    hasNonContiguousSources = true
                    sourceStarts[source] = IndexEntry(index: index, epoch: epoch)
                } else if index > 0, sources[index - 1] != source {
                    hasNonContiguousSources = true
                }
            } else {
                sourceStarts[source] = IndexEntry(index: index, epoch: epoch)
            }
        }
        // When sources are contiguous, only the row immediately after the splice
        // can be the surviving tail of a source whose first row was removed; if
        // that source still exists earlier with a gap before `newEnd`, mark
        // sources non-contiguous so future removals rebuild cleanly.
        if newEnd < sources.count {
            let tailSource = sources[newEnd]
            if sourceStart(for: tailSource) == nil {
                sourceStarts[tailSource] = IndexEntry(index: newEnd, epoch: epoch)
            } else if newEnd > 0, sources[newEnd - 1] != tailSource {
                hasNonContiguousSources = true
            }
        }
        updateTreeAfterReplace(start: start)
    }

    private mutating func updateTreeAfterReplace(start: Int) {
        // Streaming tail appends touch only the last few nodes; mid-history
        // splices run an allocation-free in-place Fenwick rebuild (~10 µs for
        // 4,000 rows).
        guard ids.count - start <= 64 else {
            rebuildTree()
            return
        }
        tree.removeSubrange((start + 1)...)
        let base = prefix(start)
        var running = base
        var suffixPrefixes: [CGFloat] = []
        suffixPrefixes.reserveCapacity(ids.count - start)
        for index in start..<ids.count {
            running += heights[index]
            suffixPrefixes.append(running)
            let node = index + 1
            let from = node - (node & -node)
            let before = from >= start ? (from == start ? base : suffixPrefixes[from - start - 1]) : prefix(from)
            tree.append(running - before)
        }
        totalHeight = running
    }

    /// Measured heights by row ID; unknown IDs and non-finite values are
    /// ignored.
    mutating func setHeights(_ updates: [String: CGFloat]) {
        for (id, height) in updates {
            guard height.isFinite, let index = index(for: id) else { continue }
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

    /// The place of a reader whose viewport top is at `top`. Pass
    /// `includeFallbacks: false` when row IDs cannot be removed (height-only
    /// updates) or `replacingRange` when replacing a known subrange so normal
    /// splices allocate nothing and never trigger COW on `ids`/`sources`.
    func readingPlace(
        atViewportTop top: CGFloat, includeFallbacks: Bool = true, replacingRange: Range<Int>? = nil
    ) -> ReadingPlace? {
        guard let index = index(at: max(0, top)) else { return nil }
        let rowTop = prefix(index)
        let source = sources[index]
        let sourceStart = sourceStart(for: source) ?? index
        let idsAbove: [String]
        let sourcesAbove: [String]
        if let range = replacingRange {
            // Rows before `range.lowerBound` are untouched by `replaceRows`.
            // If the anchor itself is outside `range`, it is guaranteed to
            // survive; if inside `range`, only rows in `range.lowerBound..<index`
            // plus the single surviving row right before `range` can ever be
            // needed as fallbacks.
            if range.contains(index) {
                let fallbackStart = max(0, range.lowerBound - 1)
                idsAbove = Array(ids[fallbackStart..<index])
                sourcesAbove = Array(sources[fallbackStart..<index])
            } else {
                idsAbove = []
                sourcesAbove = []
            }
        } else if includeFallbacks {
            idsAbove = Array(ids[..<index])
            sourcesAbove = Array(sources[..<index])
        } else {
            idsAbove = []
            sourcesAbove = []
        }
        return ReadingPlace(
            anchorID: ids[index], offsetIntoRow: top - rowTop, source: source,
            offsetIntoSource: rowTop - prefix(sourceStart) + top - rowTop,
            idsAbove: idsAbove, sourcesAbove: sourcesAbove)
    }

    /// Where a place taken before the rows changed is now. While its row
    /// stays, that row, its offset clamped to the row's new height. Else the
    /// same distance into the rows now showing its content; else just below
    /// the nearest row above it that stayed. Nil if nothing it knew stayed.
    func offset(for place: ReadingPlace) -> CGFloat? {
        if let index = index(for: place.anchorID) {
            return prefix(index) + min(place.offsetIntoRow, heights[index])
        }
        if let start = sourceStart(for: place.source) {
            let startY = prefix(start)
            return startY + min(place.offsetIntoSource, sourceEnd(from: start) - startY)
        }
        for index in place.idsAbove.indices.reversed() {
            if let kept = self.index(for: place.idsAbove[index]) { return prefix(kept + 1) }
            if let start = sourceStart(for: place.sourcesAbove[index]) { return sourceEnd(from: start) }
        }
        return nil
    }

    /// Where a saved place from an earlier session of this thread is now.
    /// Matches by row ID first, then by source ID (for example a message still
    /// represented as `.pendingMessage` before initial parse). Nil if neither
    /// exists in the loaded rows.
    func offset(for saved: TranscriptSavedPlace) -> CGFloat? {
        if let index = index(for: saved.anchorID) {
            return prefix(index) + min(saved.offsetIntoRow, heights[index])
        }
        if let start = sourceStart(for: saved.source) {
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
        edits.removeAll(keepingCapacity: true)
        indices.removeAll(keepingCapacity: true)
        indices.reserveCapacity(ids.count)
        sourceStarts.removeAll(keepingCapacity: true)
        sourceStarts.reserveCapacity(sources.count)
        hasDuplicateIDs = false
        hasNonContiguousSources = false
        for index in ids.indices {
            let id = ids[index]
            if indices[id] == nil {
                indices[id] = IndexEntry(index: index, epoch: 0)
            } else {
                hasDuplicateIDs = true
            }
            let source = sources[index]
            if sourceStarts[source] == nil {
                sourceStarts[source] = IndexEntry(index: index, epoch: 0)
            } else if index > 0, sources[index - 1] != source {
                hasNonContiguousSources = true
            }
        }
    }

    private mutating func rebuildTree() {
        let count = heights.count
        tree.removeAll(keepingCapacity: true)
        tree.reserveCapacity(count + 1)
        tree.append(0)
        guard count > 0 else {
            totalHeight = 0
            return
        }
        tree.append(contentsOf: heights)
        var sum: CGFloat = 0
        for node in 1...count {
            sum += heights[node - 1]
            let parent = node + (node & -node)
            if parent <= count { tree[parent] += tree[node] }
        }
        totalHeight = sum
    }
}
