import AppKit
import Foundation
import SwiftUI
import Testing

@testable import mai

#if os(macOS)
    struct ChatVirtualTranscriptGeometryTests {
        @Test func preservesAnchorAcrossPrependAndHeightCorrection() throws {
            var geometry = ChatVirtualTranscriptGeometry()
            geometry.replace(ids: ["a", "b", "c"], estimatedHeight: 100)
            let anchor = try #require(geometry.anchor(at: 125))
            geometry.replace(ids: ["older", "a", "b", "c"], estimatedHeight: 70)
            #expect(geometry.offset(for: anchor) == 195)
            geometry.updateHeights(["older": 90, "a": 120, "c": 500])
            #expect(geometry.offset(for: anchor) == 235)
            #expect(geometry.totalHeight == 810)
        }

        @Test func emptyRemovalAndBoundaryLookup() throws {
            var geometry = ChatVirtualTranscriptGeometry()
            #expect(geometry.index(at: 0) == nil)
            geometry.replace(ids: ["a", "b", "c"], estimatedHeight: 100)
            #expect(geometry.index(at: -1) == 0)
            #expect(geometry.index(at: 100) == 1)
            #expect(geometry.index(at: 300) == 2)
            let removed = try #require(geometry.anchor(at: 150))
            geometry.replace(ids: ["a", "c"], estimatedHeight: 100)
            #expect(geometry.offset(for: removed) == nil)
            #expect(geometry.index(for: "c") == 1)
            geometry.replace(ids: [], estimatedHeight: 100)
            #expect(geometry.totalHeight == 0)
        }

        @Test func streamingTailGrowthLeavesHistoryPositionsUnchanged() {
            var geometry = ChatVirtualTranscriptGeometry()
            let ids = (0..<5850).map { "row-\($0)" }
            geometry.replace(ids: ids, estimatedHeight: 100)
            let history = Array(geometry.offsets.dropLast())
            for height in [CGFloat(120), 150, 800, 40] {
                geometry.updateHeights(["row-5849": height])
                #expect(Array(geometry.offsets.dropLast()) == history)
                let expectedHeight: CGFloat = 584900 + height
                #expect(geometry.totalHeight == expectedHeight)
            }
        }

        @Test func reflowKeepsRowAnchorAndClampsShrinkingRowOffset() throws {
            var geometry = ChatVirtualTranscriptGeometry()
            geometry.replace(ids: ["a", "b", "c"], estimatedHeight: 100)
            let anchor = try #require(geometry.anchor(at: 175))
            geometry.updateHeights(["a": 200, "b": 30])
            #expect(geometry.offset(for: anchor) == 230)
            geometry.updateHeights(["a": .nan, "b": .infinity, "absent": 500])
            #expect(geometry.totalHeight == 330)
        }
        @Test @MainActor func coordinatorOnlyMeasuresNewOrChangedCompletedRows() async {
            let coordinator = ChatNativeTranscript<Text>.Coordinator()
            var ids = ["a", "b", "c"]
            var keys = ids.map {
                Optional(
                    ChatNativeRowMeasurementKey.source(
                        $0, role: "assistant", first: true, last: true))
            }
            coordinator.update(
                ids: ids, width: 300, measurementKeys: keys, nativeRowFactory: nil, onAttach: nil
            ) { Text("Row \($0)") }
            await coordinator.task?.value
            #expect(coordinator.lastMeasuredRowCount == 3)
            ids.append("d")
            keys.append(.source("d", role: "assistant", first: true, last: true))
            coordinator.update(
                ids: ids, width: 300, measurementKeys: keys, nativeRowFactory: nil, onAttach: nil
            ) { Text("Row \($0)") }
            await coordinator.task?.value
            #expect(coordinator.lastMeasuredRowCount == 1)
            coordinator.virtualDocument.geometry.updateHeights(["d": 350])
            coordinator.update(
                ids: ids, width: 300, measurementKeys: keys, nativeRowFactory: nil, onAttach: nil
            ) { Text("Row \($0)") }
            await coordinator.task?.value
            #expect(coordinator.lastMeasuredRowCount == 0)
            #expect(coordinator.virtualDocument.geometry.heights.last == 350)
            keys[1] = .source("changed", role: "assistant", first: true, last: true)
            coordinator.update(
                ids: ids, width: 300, measurementKeys: keys, nativeRowFactory: nil, onAttach: nil
            ) { Text("Row \($0)") }
            await coordinator.task?.value
            #expect(coordinator.lastMeasuredRowCount == 1)
            let oldRevision = coordinator.virtualDocument.rowRevisions["a"]
            coordinator.update(
                ids: ids, width: 300, measurementKeys: keys, presentationTheme: .light,
                nativeRowFactory: nil, onAttach: nil
            ) { Text("Row \($0)") }
            await coordinator.task?.value
            #expect(coordinator.lastMeasuredRowCount == 0)
            #expect(coordinator.virtualDocument.rowRevisions["a"] != oldRevision)
            let themedRevision = coordinator.virtualDocument.rowRevisions["a"]
            coordinator.update(
                ids: ids, width: 300, measurementKeys: keys, presentationTheme: .light,
                nativeRowFactory: nil, onAttach: nil
            ) { Text("Row \($0)") }
            await coordinator.task?.value
            #expect(coordinator.virtualDocument.rowRevisions["a"] == themedRevision)
        }

        @Test @MainActor func refreshingAnActiveRowKeepsItsHeightReporterValid() async {
            let coordinator = ChatNativeTranscript<Text>.Coordinator()
            coordinator.update(ids: ["active"], width: 300, nativeRowFactory: nil, onAttach: nil) { _ in Text("Reply") }
            await coordinator.task?.value
            let revision = coordinator.virtualDocument.rowRevisions["active", default: 0]
            coordinator.update(ids: ["active"], width: 300, nativeRowFactory: nil, onAttach: nil) { _ in Text("Reply") }
            await coordinator.task?.value
            coordinator.virtualDocument.noteHeight(150, id: "active", revision: revision)
            await coordinator.virtualDocument.heightUpdateTask?.value
            #expect(coordinator.virtualDocument.geometry.heights == [150])
        }

        @Test @MainActor func nativeControllerPreservesAnchorThroughHeightChangeAndPrepend()
            async throws
        {
            let document = ChatNativeTranscript<Text>.VirtualDocument()
            document.nativeRowFactory = { _, reused in reused ?? NSView() }
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            scroll.documentView = document
            let ids = (0..<10).map { "row-\($0)" }
            document.install(heights: Array(repeating: 100, count: 10), width: 300, ids: ids) {
                Text("Row \($0)")
            }
            let preserver = ChatMacScrollPositionPreserver()
            preserver.attach(to: document)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 350))
            for _ in 0..<20 { await Task.yield() }
            let anchor = try #require(document.geometry.anchor(at: scroll.contentView.bounds.minY))
            document.noteHeight(200, id: "row-0", revision: document.rowRevisions["row-0"] ?? 0)
            await document.heightUpdateTask?.value
            for _ in 0..<20 { await Task.yield() }
            #expect(scroll.contentView.bounds.minY == 450)
            #expect(document.geometry.anchor(at: scroll.contentView.bounds.minY) == anchor)
            preserver.captureBeforePrepend(leadingRowCount: 2)
            document.install(
                heights: [20, 50] + document.geometry.heights, width: 300,
                ids: ["older-a", "older-b"] + ids, changedIDs: ["older-a", "older-b"]
            ) { Text("Row \($0)") }
            for _ in 0..<20 { await Task.yield() }
            #expect(scroll.contentView.bounds.minY == 520)
            #expect(document.geometry.anchor(at: scroll.contentView.bounds.minY) == anchor)
            // Viewport resizing can produce an AppKit origin adjustment without
            // any user scroll. It must not become a new reading position.
            var resizedBounds = scroll.contentView.bounds
            resizedBounds.size.width -= 30
            resizedBounds.size.height -= 30
            resizedBounds.origin.y += 5.5
            scroll.contentView.bounds = resizedBounds
            for _ in 0..<20 { await Task.yield() }
            #expect(abs(scroll.contentView.bounds.minY - 520) < 0.000001)
            #expect(preserver.pinToBottom())
            #expect(abs(scroll.contentView.bounds.maxY - document.bounds.maxY) < 0.000001)
            document.preparationTask?.cancel()
        }

        @Test @MainActor func userScrollCancelsInitialAlignmentWithoutHidingTimeline() async {
            let document = ChatNativeTranscript<Text>.VirtualDocument()
            document.nativeRowFactory = { _, reused in reused ?? NSView() }
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            scroll.documentView = document
            document.install(heights: Array(repeating: 100, count: 10), width: 300) {
                Text("Row \($0)")
            }
            let preserver = ChatMacScrollPositionPreserver()
            preserver.attach(to: document)
            var completed = 0
            preserver.beginInitialBottomAlignment { completed += 1 }
            NotificationCenter.default.post(
                name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 350))
            for _ in 0..<20 { await Task.yield() }
            #expect(completed == 1)
            #expect(scroll.contentView.bounds.minY == 350)
            NotificationCenter.default.post(
                name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            document.preparationTask?.cancel()
        }

    }
#endif
