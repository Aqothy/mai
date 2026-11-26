import CoreGraphics
import Foundation
import Testing

@testable import mai

/// `TranscriptGeometry.replaceRows` keeps a shift log so a splice touches only
/// the rows it replaces. A splice whose next row starts another source keeps
/// sources contiguous and must stay on that log; flagging it non-contiguous
/// sends the next splice through `rebuildIndex`, rehashing every row
/// (`geometry-10k-50-splices`, Profile: 0.5 ms -> 26 ms when it did).
nonisolated struct TranscriptGeometryShiftLogTests {
    /// `applyParsedMessages`: a pending message mid-history becomes its
    /// blocks, and the next row is another message's first row. Sources stay
    /// contiguous, so consecutive drains must stay on the shift log.
    @Test func parsingMessagesMidHistoryStaysOnTheShiftLog() throws {
        var geometry = TranscriptGeometry()
        geometry.replace(
            ids: (0..<1_000).map { "m\($0)#pending" }, sources: (0..<1_000).map { "m\($0)" }
        ) { _ in 60 }
        for message in [500, 400, 300] {
            let index = try #require(geometry.index(for: "m\(message)#pending"))
            geometry.replaceRows(
                index..<(index + 1), ids: ["m\(message)#0", "m\(message)#1"],
                sources: ["m\(message)", "m\(message)"], heights: [30, 40])
            #expect(!geometry.debugHasNonContiguousSources, "after parsing m\(message)")
        }
        // One pending edit per splice; a rehash in between empties the log.
        #expect(geometry.debugPendingEditCount == 3)
    }

    /// `applyStreamRows`: a streamed message gains a block while the working
    /// row follows it.
    @Test func streamingABlockBeforeTheWorkingRowStaysOnTheShiftLog() {
        let history = (0..<2_000).map { "h\($0)" }
        var geometry = TranscriptGeometry()
        geometry.replace(ids: history + ["t|m#0", "working"], sources: history + ["t|m", "working"]) { _ in 40 }
        for blocks in 2...4 {
            geometry.replaceRows(
                2_000..<(2_000 + blocks - 1), ids: (0..<blocks).map { "t|m#\($0)" },
                sources: Array(repeating: "t|m", count: blocks), heights: Array(repeating: 40, count: blocks))
            #expect(!geometry.debugHasNonContiguousSources, "after block \(blocks)")
        }
        #expect(geometry.debugPendingEditCount == 3)
    }

    /// Same-size (`delta == 0`) splices shift no surviving rows and must not
    /// grow the edit log or trigger premature compaction.
    @Test func sameSizeSplicesDoNotAppendToTheShiftLog() {
        let ids = (0..<200).map { "r\($0)" }
        var geometry = TranscriptGeometry()
        geometry.replace(ids: ids, sources: ids) { _ in 40 }
        for step in 0..<80 {
            geometry.replaceRows(100..<101, ids: ["s\(step)"], sources: ["s\(step)"], heights: [42])
        }
        #expect(geometry.debugPendingEditCount == 0)
        #expect(geometry.index(for: "s79") == 100)
        #expect(geometry.index(for: "r199") == 199)
    }

    /// Arbitrary splices (removals, insertions, shared and reused sources,
    /// duplicate IDs) and height changes agree with a geometry rebuilt from
    /// scratch on every ID, source start and offset, across compactions.
    @Test(arguments: 0..<12)
    func randomSplicesAndHeightsMatchARebuild(seed: Int) {
        var rng = FuzzRNG(seed: 0x6E0_5EED &+ UInt64(seed))
        // Even seeds keep IDs unique and sources mostly contiguous so long
        // runs stay on the fast path and cross the 64-edit compaction.
        let duplicatePercent = seed.isMultiple(of: 2) ? 0 : 12
        let scatteredSourcePercent = seed.isMultiple(of: 2) ? 2 : 10
        var counter = 0
        var ids: [String] = []
        var sources: [String] = []
        var heights: [CGFloat] = []
        for index in 0..<40 {
            ids.append("r\(index)")
            sources.append("s\(index / 3)")
            heights.append(CGFloat(rng.int(in: 1..<90)))
        }
        var geometry = TranscriptGeometry()
        geometry.replace(ids: ids, sources: sources) { heights[$0] }
        var everIDs = Set(ids)
        var everSources = Set(sources)

        for step in 0..<(300 * TranscriptFuzz.scale) {
            if rng.chance(20), !ids.isEmpty {
                var updates: [String: CGFloat] = [:]
                for _ in 0..<rng.int(in: 1..<4) {
                    updates[rng.pick(ids)] = CGFloat(rng.int(in: 1..<90))
                }
                geometry.setHeights(updates)
                for (id, height) in updates {
                    if let index = ids.firstIndex(of: id) { heights[index] = height }
                }
            } else {
                let start = rng.int(in: 0..<(ids.count + 1))
                let end = start + rng.int(in: 0..<(min(4, ids.count - start) + 1))
                let newCount = rng.int(in: 0..<(ids.count > 120 ? 2 : 5))
                var newIDs: [String] = []
                var newSources: [String] = []
                var newHeights: [CGFloat] = []
                for _ in 0..<newCount {
                    let id: String
                    if !ids.isEmpty, rng.int(in: 0..<100) < duplicatePercent {
                        id = rng.pick(ids)
                    } else {
                        counter += 1
                        id = "n\(counter)"
                    }
                    let roll = rng.int(in: 0..<100)
                    let source: String
                    if roll < scatteredSourcePercent, !sources.isEmpty {
                        source = rng.pick(sources)
                    } else if roll < 45, start > 0 {
                        source = sources[start - 1]
                    } else if roll < 80, end < sources.count {
                        source = sources[end]
                    } else {
                        counter += 1
                        source = "f\(counter)"
                    }
                    newIDs.append(id)
                    newSources.append(source)
                    newHeights.append(CGFloat(rng.int(in: 1..<90)))
                }
                geometry.replaceRows(start..<end, ids: newIDs, sources: newSources, heights: newHeights)
                ids.replaceSubrange(start..<end, with: newIDs)
                sources.replaceSubrange(start..<end, with: newSources)
                heights.replaceSubrange(start..<end, with: newHeights)
                everIDs.formUnion(newIDs)
                everSources.formUnion(newSources)
            }
            if let mismatch = mismatch(
                geometry, ids: ids, sources: sources, heights: heights, everIDs: everIDs, everSources: everSources)
            {
                Issue.record("seed \(seed) step \(step): \(mismatch)")
                return
            }
        }
    }

    private func mismatch(
        _ geometry: TranscriptGeometry, ids: [String], sources: [String], heights: [CGFloat],
        everIDs: Set<String>, everSources: Set<String>
    ) -> String? {
        var rebuilt = TranscriptGeometry()
        rebuilt.replace(ids: ids, sources: sources) { heights[$0] }
        if geometry.ids != ids { return "ids differ" }
        if geometry.sources != sources { return "sources differ" }
        if geometry.heights != heights { return "heights differ" }
        if geometry.totalHeight != rebuilt.totalHeight {
            return "total \(geometry.totalHeight) vs \(rebuilt.totalHeight)"
        }
        for index in 0...ids.count where geometry.offset(at: index) != rebuilt.offset(at: index) {
            return "offset(at: \(index)) \(geometry.offset(at: index)) vs \(rebuilt.offset(at: index))"
        }
        for id in everIDs where geometry.index(for: id) != rebuilt.index(for: id) {
            return "index(for: \(id)) \(String(describing: geometry.index(for: id))) vs "
                + "\(String(describing: rebuilt.index(for: id)))"
        }
        for source in everSources {
            let saved = TranscriptSavedPlace(
                anchorID: "\u{0}missing", offsetIntoRow: 0, source: source, offsetIntoSource: 7, expandedTurnIDs: [])
            let incremental = geometry.offset(for: saved)
            let expected = rebuilt.offset(for: saved)
            if incremental != expected {
                return "source \(source): \(String(describing: incremental)) vs \(String(describing: expected))"
            }
        }
        return nil
    }
}
