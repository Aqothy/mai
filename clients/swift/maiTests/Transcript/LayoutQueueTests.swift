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
        let queue = LayoutQueue(concurrency: 1) { _ in
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
}
