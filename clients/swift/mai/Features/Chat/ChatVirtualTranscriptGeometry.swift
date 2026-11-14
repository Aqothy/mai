import Foundation

/// Keyed row geometry, independent of SwiftUI and AppKit view lifetimes.
/// Structural changes rebuild the index; a batch of height changes updates
/// only the affected suffix. Streaming growth in the last row is constant work.
nonisolated struct ChatVirtualTranscriptGeometry {
    struct Anchor: Equatable {
        let id: String
        let offsetWithinRow: CGFloat
    }

    private(set) var ids: [String] = []
    /// The content each row shows. The rows one piece of content is split
    /// into share it: a reply streams as one row and settles into a row
    /// per block, all showing the same message.
    private(set) var sources: [String] = []
    private(set) var heights: [CGFloat] = []
    private(set) var offsets: [CGFloat] = [0]
    private var indices: [String: Int] = [:]
    private var sourceStarts: [String: Int] = [:]

    var totalHeight: CGFloat { offsets.last ?? 0 }

    /// Row IDs should be unique. A duplicate degrades to the first row with
    /// that ID instead of trapping, matching SwiftUI's `ForEach`. Returns
    /// false when the rows are the ones already held: most updates only
    /// refresh content, and rebuilding the index for them is wasted work.
    /// A row's source is derived from the row, so the same IDs have the
    /// same sources; without sources, each row is its own.
    @discardableResult
    mutating func replace(
        ids: [String], sources: [String]? = nil, estimatedHeight: CGFloat
    ) -> Bool {
        guard ids != self.ids else { return false }
        let previous = Dictionary(zip(self.ids, heights), uniquingKeysWith: { first, _ in first })
        self.ids = ids
        if let sources, sources.count == ids.count {
            self.sources = sources
        } else {
            self.sources = ids
        }
        indices = Dictionary(
            ids.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        sourceStarts = Dictionary(
            self.sources.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        heights = ids.map { previous[$0] ?? max(1, estimatedHeight) }
        offsets = Array(repeating: 0, count: ids.count + 1)
        rebuildOffsets(from: 0)
        return true
    }

    /// Sets every row's height by position, for an install that measured
    /// the whole transcript.
    mutating func setHeights(_ newHeights: [CGFloat]) {
        guard newHeights.count == heights.count else { return }
        var earliest: Int?
        for index in newHeights.indices where newHeights[index].isFinite {
            let height = max(1, newHeights[index])
            guard heights[index] != height else { continue }
            heights[index] = height
            if earliest == nil { earliest = index }
        }
        if let earliest { rebuildOffsets(from: earliest) }
    }

    mutating func updateHeights(_ updates: [String: CGFloat]) {
        var earliest: Int?
        for (id, height) in updates {
            guard height.isFinite, let index = indices[id] else { continue }
            let height = max(1, height)
            guard heights[index] != height else { continue }
            heights[index] = height
            earliest = min(earliest ?? index, index)
        }
        if let earliest { rebuildOffsets(from: earliest) }
    }

    func index(at y: CGFloat) -> Int? {
        guard !ids.isEmpty else { return nil }
        var lower = 0
        var upper = ids.count
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            if offsets[middle] <= y { lower = middle } else { upper = middle - 1 }
        }
        return min(lower, ids.count - 1)
    }

    func anchor(at y: CGFloat) -> Anchor? {
        guard let index = index(at: y) else { return nil }
        return Anchor(id: ids[index], offsetWithinRow: max(0, y - offsets[index]))
    }

    /// The row a reader at `top` is reading, and how far `top` is into it:
    /// negative while the viewport rubber-bands above the first row. Rows no
    /// taller than `markerHeight` are passed over; the pagination marker
    /// stays first when older rows arrive below it, so it cannot say where
    /// the reader was.
    func readingAnchor(atViewportTop top: CGFloat, markerHeight: CGFloat) -> Anchor? {
        guard var index = index(at: max(0, top)) else { return nil }
        while index < ids.count - 1, heights[index] <= markerHeight {
            index += 1
        }
        return Anchor(id: ids[index], offsetWithinRow: top - offsets[index])
    }

    func offset(for anchor: Anchor) -> CGFloat? {
        guard let index = indices[anchor.id] else { return nil }
        return offsets[index] + min(anchor.offsetWithinRow, heights[index])
    }

    /// The place of a reader at `top`; see `readingAnchor`.
    func readingPlace(atViewportTop top: CGFloat, markerHeight: CGFloat)
        -> ChatTranscriptReadingPlace?
    {
        guard let anchor = readingAnchor(atViewportTop: top, markerHeight: markerHeight),
            let index = indices[anchor.id]
        else { return nil }
        let source = sources[index]
        let sourceStart = sourceStarts[source] ?? index
        return ChatTranscriptReadingPlace(
            anchor: anchor, source: source,
            offsetIntoSource: offsets[index] - offsets[sourceStart] + anchor.offsetWithinRow,
            idsAbove: ids[..<index], sourcesAbove: sources[..<index])
    }

    /// Where a reading place taken before the rows changed is now. While
    /// its row stays, that is the row. Otherwise the reader keeps their
    /// place in the rows now showing its content, or, when it folded
    /// away, lands where it was: below the nearest row above it that
    /// stayed.
    func offset(for place: ChatTranscriptReadingPlace) -> CGFloat? {
        if let offset = offset(for: place.anchor) { return offset }
        if let start = sourceStarts[place.source] {
            return offsets[start]
                + min(place.offsetIntoSource, sourceEnd(from: start) - offsets[start])
        }
        for index in place.idsAbove.indices.reversed() {
            if let kept = indices[place.idsAbove[index]] { return offsets[kept + 1] }
            if let start = sourceStarts[place.sourcesAbove[index]] { return sourceEnd(from: start) }
        }
        return nil
    }

    /// The bottom of the run of rows showing the source of row `start`.
    private func sourceEnd(from start: Int) -> CGFloat {
        var end = start + 1
        while end < sources.count, sources[end] == sources[start] { end += 1 }
        return offsets[end]
    }

    /// The rows to keep mounted for a viewport spanning `top..<bottom`: the
    /// rows it shows, and one viewport's height of rows on either side so
    /// a scroll finds its next rows ready. Nil without rows.
    func tiling(top: CGFloat, bottom: CGFloat) -> (
        resident: ClosedRange<Int>, visible: ClosedRange<Int>
    )? {
        guard !ids.isEmpty else { return nil }
        let height = bottom - top
        let first = index(at: max(0, top - height)) ?? 0
        let last = max(first, index(at: min(totalHeight, bottom + height)) ?? first)
        let visibleFirst = min(last, max(first, index(at: max(0, top)) ?? first))
        let visibleLast = max(visibleFirst, min(last, index(at: min(totalHeight, bottom)) ?? last))
        return (first...last, visibleFirst...visibleLast)
    }

    func index(for id: String) -> Int? { indices[id] }

    private mutating func rebuildOffsets(from first: Int) {
        for index in first..<heights.count {
            offsets[index + 1] = offsets[index] + heights[index]
        }
    }
}
