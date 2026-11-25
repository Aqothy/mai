import CoreGraphics
import Foundation
import Testing

@testable import mai

/// PLAN 3.9 rule 4's geometry: heights by row, offsets, and where a reading
/// place is after the rows change. Cases from `ChatVirtualTranscriptGeometryTests`.
nonisolated struct TranscriptGeometryTests {
    private func geometry(_ ids: [String], sources: [String]? = nil, height: CGFloat) -> TranscriptGeometry {
        var geometry = TranscriptGeometry()
        geometry.replace(ids: ids, sources: sources ?? ids) { _ in height }
        return geometry
    }

    @Test func preservesAnchorAcrossPrependAndHeightCorrection() throws {
        var geometry = geometry(["a", "b", "c"], height: 100)
        let place = try #require(geometry.readingPlace(atViewportTop: 125))
        geometry.replace(ids: ["older", "a", "b", "c"], sources: ["older", "a", "b", "c"]) { _ in 70 }
        #expect(geometry.offset(for: place) == 195)
        geometry.setHeights(["older": 90, "a": 120, "c": 500])
        #expect(geometry.offset(for: place) == 235)
        #expect(geometry.totalHeight == 810)
    }

    /// A row that left still says where the reader was: in the rows now
    /// showing its content, or below the nearest row above it that stayed.
    @Test func placeWhoseRowLeftFindsItsContentOrTheRowAboveIt() throws {
        var geometry = geometry(
            ["user", "header", "work", "live", "working"],
            sources: ["user", "header", "work", "m", "working"], height: 100)
        geometry.setHeights(["user": 100, "header": 40, "work": 300, "live": 900, "working": 40])
        let inReply = try #require(geometry.readingPlace(atViewportTop: 940))
        let inWork = try #require(geometry.readingPlace(atViewportTop: 200))

        geometry.replace(
            ids: ["user", "header", "m#0", "m#1"], sources: ["user", "header", "m", "m"]
        ) { _ in 100 }
        geometry.setHeights(["user": 100, "header": 40, "m#0": 300, "m#1": 500])
        #expect(geometry.offset(for: inReply) == CGFloat(140 + 500))
        #expect(geometry.offset(for: inWork) == 140)
    }

    @Test func emptyRemovalAndBoundaryLookup() throws {
        var geometry = TranscriptGeometry()
        #expect(geometry.index(at: 0) == nil)
        geometry = self.geometry(["a", "b", "c"], height: 100)
        #expect(geometry.index(at: -1) == 0)
        #expect(geometry.index(at: 100) == 1)
        #expect(geometry.index(at: 300) == 2)
        let removed = try #require(geometry.readingPlace(atViewportTop: 150))
        geometry.replace(ids: ["a", "c"], sources: ["a", "c"]) { _ in 100 }
        // "b" left, and its content with it: the reader lands below "a".
        #expect(geometry.offset(for: removed) == 100)
        #expect(geometry.index(for: "c") == 1)
        geometry.replace(ids: [], sources: []) { _ in 100 }
        #expect(geometry.totalHeight == 0)
        #expect(geometry.offset(for: removed) == nil)
    }

    @Test func duplicateIDsResolveToTheFirstRowInsteadOfTrapping() {
        var geometry = geometry(["a", "dup", "dup"], height: 100)
        #expect(geometry.index(for: "dup") == 1)
        geometry.setHeights(["dup": 50])
        #expect(geometry.totalHeight == 250)
        geometry.replace(ids: ["dup", "dup", "b"], sources: ["dup", "dup", "b"]) { _ in 100 }
        #expect(geometry.index(for: "dup") == 0)
        #expect(geometry.totalHeight == 200)
    }

    @Test func streamingTailGrowthLeavesHistoryPositionsUnchanged() {
        let ids = (0..<5850).map { "row-\($0)" }
        var geometry = geometry(ids, height: 100)
        let history = (0..<5849).map { geometry.offset(at: $0) }
        for height in [CGFloat(120), 150, 800, 40] {
            geometry.setHeights(["row-5849": height])
            #expect((0..<5849).map { geometry.offset(at: $0) } == history)
            #expect(geometry.totalHeight == 584_900 + height)
        }
    }

    /// Replacing a range (a streamed message gaining blocks) gives the same
    /// offsets and lookups as rebuilding everything.
    @Test(arguments: [0, 5, 37, 63, 64])
    func replacingARangeMatchesARebuild(start: Int) {
        let ids = (0..<64).map { "row-\($0)" }
        var incremental = geometry(ids, height: 10)
        for (index, id) in ids.enumerated() { incremental.setHeights([id: CGFloat(10 + index % 9)]) }
        let replaced = ["new-a", "new-b", "new-c"]
        let end = min(ids.count, start + 2)
        incremental.replaceRows(
            start..<end, ids: replaced, sources: ["m", "m", "m"], heights: [30, 40, 50])
        let finalIDs = Array(ids[..<start]) + replaced + Array(ids[end...])
        let finalSources = Array(ids[..<start]) + ["m", "m", "m"] + Array(ids[end...])
        var rebuilt = TranscriptGeometry()
        rebuilt.replace(ids: finalIDs, sources: finalSources) { index in
            if let original = ids.firstIndex(of: finalIDs[index]) { return CGFloat(10 + original % 9) }
            return [30, 40, 50][replaced.firstIndex(of: finalIDs[index]) ?? 0]
        }
        #expect(incremental.totalHeight == rebuilt.totalHeight)
        for index in 0...finalIDs.count {
            #expect(incremental.offset(at: index) == rebuilt.offset(at: index), "offset \(index)")
        }
        for id in finalIDs { #expect(incremental.index(for: id) == rebuilt.index(for: id)) }
        for y in stride(from: CGFloat(0), to: rebuilt.totalHeight, by: 7) {
            #expect(incremental.index(at: y) == rebuilt.index(at: y))
        }
        let place = rebuilt.readingPlace(atViewportTop: 100)
        #expect(place.flatMap(incremental.offset(for:)) == place.flatMap(rebuilt.offset(for:)))
    }

    @Test func reflowKeepsRowAnchorAndClampsShrinkingRowOffset() throws {
        var geometry = geometry(["a", "b", "c"], height: 100)
        let place = try #require(geometry.readingPlace(atViewportTop: 175))
        geometry.setHeights(["a": 200, "b": 30])
        #expect(geometry.offset(for: place) == 230)
        geometry.setHeights(["a": .nan, "b": .infinity, "absent": 500])
        #expect(geometry.totalHeight == 330)
    }

    /// Expanding, shrinking, and equal-length `replaceRows` with shared
    /// multi-block sources and duplicate IDs must match a full rebuild.
    @Test(arguments: [0, 1, 2, 3, 4])
    func replaceRowsHandlesGrowthShrinkAndSharedSources(replacementCount: Int) {
        let initialIDs = ["u0", "m0#pending", "u1", "m1#0", "m1#1", "m1#2", "dup", "dup", "tail"]
        let initialSources = ["u0", "m0", "u1", "m1", "m1", "m1", "dup", "dup", "tail"]
        var incremental = geometry(initialIDs, sources: initialSources, height: 40)
        let newIDs = (0..<replacementCount).map { "m0#\($0)" }
        let newSources = Array(repeating: "m0", count: replacementCount)
        let newHeights = (0..<replacementCount).map { CGFloat(25 + $0 * 10) }

        incremental.replaceRows(1..<3, ids: newIDs, sources: newSources, heights: newHeights)

        let finalIDs = Array(initialIDs[..<1]) + newIDs + Array(initialIDs[3...])
        let finalSources = Array(initialSources[..<1]) + newSources + Array(initialSources[3...])
        var rebuilt = TranscriptGeometry()
        rebuilt.replace(ids: finalIDs, sources: finalSources) { index in
            if index >= 1, index < 1 + replacementCount { return newHeights[index - 1] }
            return 40
        }

        #expect(incremental.totalHeight == rebuilt.totalHeight)
        for id in Set(initialIDs + finalIDs) {
            #expect(incremental.index(for: id) == rebuilt.index(for: id), "id \(id)")
        }
        for source in Set(initialSources + finalSources) {
            let saved = TranscriptSavedPlace(
                anchorID: "missing", offsetIntoRow: 0, source: source, offsetIntoSource: 10, expandedTurnIDs: [])
            #expect(incremental.offset(for: saved) == rebuilt.offset(for: saved), "source \(source)")
        }
    }

    /// Pure insertion (`range.isEmpty`), multi-message batch expansion past
    /// `oldEnd`, and equal-length replacement dropping the first row of a
    /// shared source must all preserve exact `index` and `sourceStarts`.
    @Test func replaceRowsHandlesInsertionsMultiMessageBatchAndEqualDeltaSharedSource() {
        func verify(_ incremental: TranscriptGeometry, matches ids: [String], sources: [String], heights: [CGFloat]) {
            var rebuilt = TranscriptGeometry()
            rebuilt.replace(ids: ids, sources: sources) { heights[$0] }
            #expect(incremental.totalHeight == rebuilt.totalHeight)
            for id in Set(ids) {
                #expect(incremental.index(for: id) == rebuilt.index(for: id), "id \(id)")
            }
            for source in Set(sources) {
                let saved = TranscriptSavedPlace(
                    anchorID: "missing", offsetIntoRow: 0, source: source, offsetIntoSource: 5, expandedTurnIDs: [])
                #expect(incremental.offset(for: saved) == rebuilt.offset(for: saved), "source \(source)")
            }
        }

        // 1. Pure insertion (range.isEmpty) of a multi-block source.
        var g1 = geometry(["u0", "u1", "tail"], sources: ["u0", "u1", "tail"], height: 40)
        g1.replaceRows(2..<2, ids: ["m#0", "m#1", "m#2"], sources: ["m", "m", "m"], heights: [30, 35, 45])
        verify(
            g1, matches: ["u0", "u1", "m#0", "m#1", "m#2", "tail"],
            sources: ["u0", "u1", "m", "m", "m", "tail"], heights: [40, 40, 30, 35, 45, 40])

        // 2. Multi-message batch expansion pushing a second multi-block source past oldEnd.
        var g2 = geometry(["u0", "m0#p", "u1", "m1#p", "tail"], sources: ["u0", "m0", "u1", "m1", "tail"], height: 40)
        g2.replaceRows(
            1..<4,
            ids: ["m0#0", "m0#1", "m0#2", "u1", "m1#0", "m1#1", "m1#2"],
            sources: ["m0", "m0", "m0", "u1", "m1", "m1", "m1"],
            heights: [20, 25, 30, 40, 22, 26, 32])
        verify(
            g2, matches: ["u0", "m0#0", "m0#1", "m0#2", "u1", "m1#0", "m1#1", "m1#2", "tail"],
            sources: ["u0", "m0", "m0", "m0", "u1", "m1", "m1", "m1", "tail"],
            heights: [40, 20, 25, 30, 40, 22, 26, 32, 40])

        // 3. Equal-length replacement (delta == 0) removing the first row of a shared source.
        var g3 = geometry(["u0", "m0#0", "m0#1", "tail"], sources: ["u0", "m0", "m0", "tail"], height: 40)
        g3.replaceRows(1..<2, ids: ["n"], sources: ["n"], heights: [50])
        verify(
            g3, matches: ["u0", "n", "m0#1", "tail"],
            sources: ["u0", "n", "m0", "tail"], heights: [40, 50, 40, 40])
    }
}
