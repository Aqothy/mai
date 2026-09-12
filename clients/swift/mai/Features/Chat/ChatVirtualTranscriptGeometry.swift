#if os(macOS)
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
        private(set) var heights: [CGFloat] = []
        private(set) var offsets: [CGFloat] = [0]
        private var indices: [String: Int] = [:]

        var totalHeight: CGFloat { offsets.last ?? 0 }

        mutating func replace(ids: [String], estimatedHeight: CGFloat) {
            let previous = Dictionary(uniqueKeysWithValues: zip(self.ids, heights))
            self.ids = ids
            indices = Dictionary(
                uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
            heights = ids.map { previous[$0] ?? max(1, estimatedHeight) }
            offsets = Array(repeating: 0, count: ids.count + 1)
            rebuildOffsets(from: 0)
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

        func offset(for anchor: Anchor) -> CGFloat? {
            guard let index = indices[anchor.id] else { return nil }
            return offsets[index] + min(anchor.offsetWithinRow, heights[index])
        }

        func index(for id: String) -> Int? { indices[id] }

        private mutating func rebuildOffsets(from first: Int) {
            for index in first..<heights.count {
                offsets[index + 1] = offsets[index] + heights[index]
            }
        }
    }
#endif
