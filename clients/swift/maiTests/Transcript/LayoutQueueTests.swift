import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import mai

nonisolated struct LayoutQueueTests {
    /// Placement prefetches every row in its drawn window without a layout on
    /// every scroll frame, so a cold row is submitted again while its job
    /// runs. The same work at the same key runs once (a second run would lay
    /// out and pre-raster `IOSurface`s that `RowLayer.show` throws away); a
    /// new width still runs after the one in flight.
    @Test func layoutQueueDeduplicatesIdenticalInFlightJobButRunsNewWidth() async throws {
        let style = await TextStyle.current()
        let count = Mutex<Int>(0)
        let queue = LayoutQueue(concurrency: 1) { _, _ in
            count.withLock { $0 += 1 }
        }
        let text = String(repeating: "duplicate check word ", count: 300)
        let kind: TranscriptRowKind = .markdownBlock(.paragraph([MarkdownInline(text: text)]), .single)
        let key1 = RowLayoutKey(contentVersion: 0, width: 420, styleVersion: style.version)
        let key2 = RowLayoutKey(contentVersion: 0, width: 320, styleVersion: style.version)
        let job1 = LayoutQueue.Job(
            id: "layout|dup",
            work: .layout(RowLayoutRequest(rowID: "dup", kind: kind, key: key1, style: style), drawing: nil),
            priority: 0)
        let job2 = LayoutQueue.Job(
            id: "layout|dup",
            work: .layout(RowLayoutRequest(rowID: "dup", kind: kind, key: key2, style: style), drawing: nil),
            priority: 0)

        await queue.submit(urgent: [job1], generation: 1, replacingUrgent: true)
        // Re-submitting identical in-flight job via prefetch must NOT run a second time.
        await queue.submit(urgent: [job1], generation: 1, replacingUrgent: false)
        for _ in 0..<100 where count.withLock({ $0 }) < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(count.withLock { $0 } == 1)

        // Submitting a new width while job1 is running MUST run both.
        await queue.submit(urgent: [job1], generation: 2, replacingUrgent: true)
        await queue.submit(urgent: [job2], generation: 3, replacingUrgent: true)
        for _ in 0..<100 where count.withLock({ $0 }) < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(count.withLock { $0 } == 3)
    }

    /// Pausing backfill synchronously suppresses in-flight and queued backfill
    /// deliveries while keeping urgent viewport jobs flowing, then delivers the
    /// paused backfill jobs once resumed.
    @Test func pausedBackfillRequeuesAndWaitsUntilResumedWhileUrgentRuns() async throws {
        let style = await TextStyle.current()
        let backfillDelivered = Mutex<[String]>([])
        let urgentDelivered = Mutex<[String]>([])
        let queue = LayoutQueue(concurrency: 2) { result, isBackfill in
            if case .layout(let layout, _) = result {
                if isBackfill {
                    backfillDelivered.withLock { $0.append(layout.rowID) }
                } else {
                    urgentDelivered.withLock { $0.append(layout.rowID) }
                }
            }
        }
        let text = String(repeating: "backfill pause word ", count: 120)
        let kind: TranscriptRowKind = .markdownBlock(.paragraph([MarkdownInline(text: text)]), .single)
        let key = RowLayoutKey(contentVersion: 0, width: 400, styleVersion: style.version)
        let backfillJobs = (0..<4).map { i in
            LayoutQueue.Job(
                id: "layout|bf-\(i)",
                work: .layout(RowLayoutRequest(rowID: "bf-\(i)", kind: kind, key: key, style: style), drawing: nil),
                priority: i)
        }
        let urgentJob = LayoutQueue.Job(
            id: "layout|urgent-0",
            work: .layout(RowLayoutRequest(rowID: "urgent-0", kind: kind, key: key, style: style), drawing: nil),
            priority: 0)

        queue.markBackfillPaused(true)
        await queue.setBackfill(backfillJobs, paused: true)
        await queue.submit(urgent: [urgentJob], generation: 1, replacingUrgent: true)
        for _ in 0..<100 where urgentDelivered.withLock({ $0.count }) < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(urgentDelivered.withLock { $0 } == ["urgent-0"])
        #expect(backfillDelivered.withLock { $0 }.isEmpty)

        queue.markBackfillPaused(false)
        await queue.setBackfillPaused(false)
        for _ in 0..<150 where backfillDelivered.withLock({ $0.count }) < backfillJobs.count {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(Set(backfillDelivered.withLock { $0 }) == Set(["bf-0", "bf-1", "bf-2", "bf-3"]))
    }

    /// Setting a text selection pauses off-screen backfill so rows above the
    /// viewport stop shifting document `y` (which flickers UIKit's selection
    /// overlay and dismisses the edit menu), then resumes once deselected.
    @MainActor
    @Test func activeSelectionDefersBackfillUntilCleared() async throws {
        let controller = TranscriptController()
        let host = StubViewportHost(viewport: TranscriptViewport(size: CGSize(width: 400, height: 300), topInset: 0, bottomInset: 0))
        controller.attach(host)

        let body = String(repeating: "Long paragraph content for backfill measurement test. ", count: 20)
        var rows: [TranscriptRow] = []
        for i in 0..<40 {
            let msg = TranscriptMessage(kind: .assistant, turnID: "t-\(i)", ref: "r-\(i)")
            rows.append(TranscriptRow(id: msg.pendingRowID, sourceID: msg.id, kind: .pendingMessage(msg, source: body)))
        }
        let targetID = "visible-end"
        rows.append(
            TranscriptRow(
                id: targetID,
                kind: .markdownBlock(.paragraph([MarkdownInline(text: "Selected target word here")]), .single)))
        controller.setRows(rows)
        for _ in 0..<100 where controller.isAwaitingInitialEnd {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!controller.isAwaitingInitialEnd)

        // Select text on the visible bottom row: backfill must pause and stop
        // shifting the selected row's document offset while selection is active.
        let sel = TranscriptSelection(
            anchor: TextPosition(rowID: targetID, offset: 0),
            focus: TextPosition(rowID: targetID, offset: 8))
        controller.setSelection(sel)
        #expect(controller.shouldPauseBackfill)
        let offsetAtSelect = controller.geometry.index(for: targetID).map { controller.geometry.offset(at: $0) }
        try await Task.sleep(for: .milliseconds(120))
        let offsetWhileSelected = controller.geometry.index(for: targetID).map { controller.geometry.offset(at: $0) }
        #expect(offsetAtSelect == offsetWhileSelected)

        // Clearing selection resumes backfill until all pending rows parse.
        controller.setSelection(nil)
        #expect(!controller.shouldPauseBackfill)
        for _ in 0..<200 where controller.rows.contains(where: { if case .pendingMessage = $0.kind { true } else { false } }) {
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(!controller.rows.contains(where: { if case .pendingMessage = $0.kind { true } else { false } }))
    }
}

@MainActor
private final class StubViewportHost: TranscriptViewportHost {
    var viewport: TranscriptViewport?
    var viewportTop: CGFloat = 0
    var scale: CGFloat = 2
    var colorSpace: CGColorSpace { RowLayer.colorSpace }
    var animatesJumps: Bool { false }

    init(viewport: TranscriptViewport) {
        self.viewport = viewport
    }

    func setDocumentHeight(_ height: CGFloat) {}
    func setViewportTop(_ top: CGFloat) { viewportTop = top }
    func setContentVisible(_ visible: Bool) {}
    func setNeedsRowPlacement() {}
    func setNeedsFrameUpdates(_ needed: Bool) {}
    func setNeedsSelectionDisplay() {}
    func selectedTextWillChange() {}
    func selectedTextDidChange() {}
    func stopDeceleration() {}
}
