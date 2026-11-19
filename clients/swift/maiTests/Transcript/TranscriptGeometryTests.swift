import CoreGraphics
import Foundation
import Testing

@testable import mai

/// PLAN 3.9 rule 4's geometry: heights by row, offsets, and where a reading
/// place is after the rows change. Cases from `ChatVirtualTranscriptGeometryTests`.
struct TranscriptGeometryTests {
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
}
