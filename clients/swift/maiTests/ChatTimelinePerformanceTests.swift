import Foundation
import XCTest

@testable import mai

private nonisolated enum ChatLifetimeTestContext {
    @TaskLocal static var marker = false
}

/// UIKit/SwiftUI can release presentation state synchronously, outside a
/// Swift task. Async tests miss the isolated-deinit runtime bug on iOS 18.6.
nonisolated final class ChatPresentationLifetimeTests: XCTestCase {
    @MainActor
    private func assertSynchronousRelease<T: AnyObject>(_ make: () -> T) {
        weak var released: T?
        ChatLifetimeTestContext.$marker.withValue(true) {
            let object = make()
            released = object
            withExtendedLifetime(object) {}
        }
        XCTAssertNil(released)
    }

    @MainActor func testProjectionRelease() {
        assertSynchronousRelease { ChatTimelineProjection() }
    }

    @MainActor func testTextLayoutStoreRelease() {
        assertSynchronousRelease { ChatTextLayoutStore() }
    }

    @MainActor func testMarkdownSegmentCacheRelease() {
        assertSynchronousRelease { ChatMarkdownSegmentCache() }
    }

    @MainActor func testAnnotationStateRelease() {
        assertSynchronousRelease { ChatAnnotationModel() }
    }

    @MainActor func testScrollStateRelease() {
        assertSynchronousRelease { ChatScrollState() }
    }

    @MainActor func testFoldStateRelease() {
        assertSynchronousRelease { ChatTimelineFoldModel() }
    }

    @MainActor func testStreamingTextRelease() {
        assertSynchronousRelease { ThreadStreamingText(text: "Hello 👋🏽") }
    }

    @MainActor func testJSONPayloadRelease() {
        assertSynchronousRelease { JSONAny(["text": "Hello"]) }
    }

    @MainActor func testJSONNullRelease() {
        assertSynchronousRelease { JSONNull() }
    }
}

/// Correctness and benchmarks for `ChatTimelineProjection`, the incremental
/// section projection behind the chat timeline.
///
/// Each benchmark pairs the previous behavior (a full re-walk of the
/// transcript per structural event) with the incremental projection on the
/// same event stream, at two transcript sizes so the scaling difference is
/// visible in the numbers themselves.
nonisolated
final class ChatTimelinePerformanceTests: XCTestCase {
    // MARK: Timeline fixtures

    @MainActor
    private func makeTimeline(
        turnCount: Int,
        itemsPerTurn: Int = 3,
        responseBytes: Int = 600
    ) -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        entries.reserveCapacity(turnCount * (2 + itemsPerTurn))
        let response = String(repeating: "Wrapped prose for the fixture. ", count: max(1, responseBytes / 32))
        for turn in 0..<turnCount {
            entries.append(
                messageEntry(
                    id: "user-\(turn)",
                    role: .user,
                    turnID: "turn-\(turn)",
                    text: "Fixturized question \(turn)?"
                )
            )
            entries.append(
                messageEntry(
                    id: "assistant-\(turn)",
                    role: .assistant,
                    turnID: "turn-\(turn)",
                    text: response
                )
            )
            for item in 0..<itemsPerTurn {
                entries.append(
                    itemEntry(
                        id: "item-\(turn)-\(item)",
                        kind: .commandExecution,
                        status: .completed,
                        turnID: "turn-\(turn)"
                    )
                )
            }
        }
        return entries
    }

    @MainActor
    private func messageEntry(
        id: String,
        role: MaidMessageRole,
        turnID: String?,
        text: String
    ) -> TimelineEntry {
        TimelineEntry(
            approval: nil,
            item: nil,
            kind: MaidTimelineEntryKind.message.rawValue,
            message: Message(
                attachments: nil,
                createdAt: Date(timeIntervalSince1970: 0),
                id: id,
                role: role.rawValue,
                text: text,
                turnID: turnID,
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        )
    }

    @MainActor
    private func itemEntry(
        id: String,
        kind: MaidItemKind,
        status: MaidItemStatus,
        turnID: String?
    ) -> TimelineEntry {
        TimelineEntry(
            approval: nil,
            item: Item(
                createdAt: Date(timeIntervalSince1970: 0),
                detailAvailable: nil,
                id: id,
                kind: kind.rawValue,
                payload: nil,
                sequence: nil,
                status: status.rawValue,
                textDelta: nil,
                title: nil,
                toolCall: nil,
                toolCallSummary: nil,
                turnID: turnID,
                updatedAt: Date(timeIntervalSince1970: 0)
            ),
            kind: MaidTimelineEntryKind.item.rawValue,
            message: nil
        )
    }

    /// Simulated structural streaming events over `initial`: returns each
    /// mutated timeline plus the invalidation index `ThreadEventReducer`
    /// would report for it. The mix matches live agent traffic — appended
    /// tool items, in-place tail updates, and (every third event) an older
    /// approval resolving mid-timeline, the one real case where live events
    /// touch non-tail entries.
    @MainActor
    private func streamedSteps(
        initial: [TimelineEntry],
        runningTurnID: String,
        eventCount: Int
    ) -> [(timeline: [TimelineEntry], firstChangedIndex: Int)] {
        var timeline = initial
        var steps: [(timeline: [TimelineEntry], firstChangedIndex: Int)] = []
        steps.reserveCapacity(eventCount)

        for event in 0..<eventCount {
            switch event % 3 {
            case 0:
                // A new tool item appends at the tail of the running turn.
                let index = timeline.count
                timeline.append(
                    itemEntry(
                        id: "streamed-item-\(event)",
                        kind: .commandExecution,
                        status: .inProgress,
                        turnID: runningTurnID
                    )
                )
                steps.append((timeline, index))
            case 1:
                // The newest entry updates in place (status/payload merge).
                var last = timeline[timeline.count - 1]
                last.item?.updatedAt = Date(timeIntervalSince1970: Double(event))
                last.item?.status = MaidItemStatus.completed.rawValue
                timeline[timeline.count - 1] = last
                steps.append((timeline, timeline.count - 1))
            default:
                // An older approval resolves mid-timeline.
                let index = timeline.count / 2
                var entry = timeline[index]
                if entry.approval == nil {
                    entry.approval = Approval(
                        args: nil,
                        createdAt: Date(timeIntervalSince1970: 0),
                        decision: nil,
                        optionID: nil,
                        options: nil,
                        requestID: "approval-\(event)",
                        status: MaidApprovalStatus.pending.rawValue,
                        turnID: nil,
                        updatedAt: Date(timeIntervalSince1970: 0)
                    )
                } else {
                    entry.approval?.decision = "allow"
                    entry.approval?.status = MaidApprovalStatus.resolved.rawValue
                }
                timeline[index] = entry
                steps.append((timeline, index))
            }
        }
        return steps
    }

    /// Content-sensitive fingerprint, not just identity: a stale projection
    /// could keep identical row IDs while showing outdated item statuses,
    /// approval decisions, or timestamps.
    @MainActor
    private func rowFingerprints(of sections: [ChatTimelineLayout.Section]) -> [String] {
        ChatTimelineLayout.rows(
            sections: sections,
            streamingTurnID: nil,
            latestTurn: nil,
            expandedSectionIDs: []
        ).map { row -> String in
            switch row {
            case .message(let message):
                return "\(row.id)|\(message.text)|\(message.updatedAt.timeIntervalSince1970)"
            case .thought(let item):
                return "\(row.id)|\(item.status)|\(item.updatedAt.timeIntervalSince1970)"
            case .activityGroup(let group):
                let items = group.items.map {
                    "\($0.id):\($0.status):\($0.updatedAt.timeIntervalSince1970)"
                }.joined(separator: ",")
                return "\(row.id)|\(items)"
            case .notice(let item):
                return "\(row.id)|\(item.status)|\(item.updatedAt.timeIntervalSince1970)"
            case .approval(let approval):
                return "\(row.id)|\(approval.status)|\(approval.decision ?? "none")"
            case .turnActivity(let activity):
                return "\(row.id)|\(activity.stepCount)|\(activity.isRunning)"
            }
        }
    }

    // MARK: Correctness

    /// Locks the incremental projection to a full rebuild after every step:
    /// identical sections through appends, tail mutations, mid-timeline
    /// mutations, snapshot replacement, coalesced invalidations, and pure
    /// cache hits.
    @MainActor
    func testIncrementalProjectionMatchesFullRebuild() {
        let initial = makeTimeline(turnCount: 40)
        let projection = ChatTimelineProjection()

        var sections = projection.project(initial)
        XCTAssertEqual(rowFingerprints(of: sections), rowFingerprints(of: ChatTimelineLayout.sections(timeline: initial)))

        var timeline = initial
        let steps = streamedSteps(
            initial: initial,
            runningTurnID: "turn-\(40 - 1)",
            eventCount: 120
        )
        for step in steps {
            timeline = step.timeline
            projection.invalidate(from: step.firstChangedIndex)
            sections = projection.project(step.timeline)
            XCTAssertEqual(
                rowFingerprints(of: sections),
                rowFingerprints(of: ChatTimelineLayout.sections(timeline: step.timeline)),
                "Incremental projection diverged from a full rebuild"
            )

            // Snapshot replacement drops leading entries; only a full
            // invalidation describes it.
            if step.firstChangedIndex == 60 {
                var replaced = step.timeline
                replaced.removeFirst(10)
                timeline = replaced
                projection.invalidateAll()
                sections = projection.project(replaced)
                XCTAssertEqual(
                    rowFingerprints(of: sections),
                    rowFingerprints(of: ChatTimelineLayout.sections(timeline: replaced))
                )
            }
        }

        // Several events may land before one body evaluation; the lowest
        // index wins.
        var coalesced = timeline
        coalesced[coalesced.count - 1].item?.status = MaidItemStatus.failed.rawValue
        projection.invalidate(from: coalesced.count - 1)
        coalesced[5].message?.text = "Edited earlier message"
        projection.invalidate(from: 5)
        coalesced[coalesced.count - 2].item?.status = MaidItemStatus.failed.rawValue
        projection.invalidate(from: coalesced.count - 2)
        timeline = coalesced
        sections = projection.project(coalesced)
        XCTAssertEqual(
            rowFingerprints(of: sections),
            rowFingerprints(of: ChatTimelineLayout.sections(timeline: coalesced))
        )

        // An unchanged timeline is a pure cache hit with identical output.
        let unchanged = projection.project(timeline)
        XCTAssertEqual(rowFingerprints(of: unchanged), rowFingerprints(of: sections))
    }

    // MARK: Benchmarks

    /// Baseline: previous behavior, where every structural streaming event
    /// re-walked the entire transcript on the main thread.
    @MainActor
    func testFullSectionProjectionBaselinePerformance() {
        let initial = makeTimeline(turnCount: 500)
        let steps = streamedSteps(initial: initial, runningTurnID: "turn-499", eventCount: 240)

        var sectionCount = 0
        measure(metrics: [XCTClockMetric()]) {
            for step in steps {
                sectionCount = ChatTimelineLayout.sections(timeline: step.timeline).count
            }
        }
        XCTAssertGreaterThan(sectionCount, 0)
    }

    /// Production: suffix-only reprojection over the same event stream.
    /// Includes the pessimistic mid-timeline mutations, so steady-state
    /// tail-only traffic (tool items, message chunks) is cheaper than this.
    @MainActor
    func testIncrementalSectionProjectionPerformance() {
        let initial = makeTimeline(turnCount: 500)
        let steps = streamedSteps(initial: initial, runningTurnID: "turn-499", eventCount: 240)

        let projection = ChatTimelineProjection()
        _ = projection.project(initial)
        var sectionCount = 0

        measure(metrics: [XCTClockMetric()]) {
            for step in steps {
                projection.invalidate(from: step.firstChangedIndex)
                sectionCount = projection.project(step.timeline).count
            }
        }
        XCTAssertGreaterThan(sectionCount, 0)
    }

    /// Scaling proof at ~10k entries: the full rebuild degrades linearly
    /// with transcript size (multiple frames per event), while the
    /// incremental projection stays flat. Compare against the 2,500-entry
    /// pair above.
    @MainActor
    func testFullSectionProjectionAtTenThousandEntriesPerformance() {
        let initial = makeTimeline(turnCount: 2_000)
        let steps = streamedSteps(initial: initial, runningTurnID: "turn-1999", eventCount: 60)

        var sectionCount = 0
        measure(metrics: [XCTClockMetric()]) {
            for step in steps {
                sectionCount = ChatTimelineLayout.sections(timeline: step.timeline).count
            }
        }
        XCTAssertGreaterThan(sectionCount, 0)
    }

    @MainActor
    func testIncrementalSectionProjectionAtTenThousandEntriesPerformance() {
        let initial = makeTimeline(turnCount: 2_000)
        let steps = streamedSteps(initial: initial, runningTurnID: "turn-1999", eventCount: 60)

        let projection = ChatTimelineProjection()
        _ = projection.project(initial)
        var sectionCount = 0

        measure(metrics: [XCTClockMetric()]) {
            for step in steps {
                projection.invalidate(from: step.firstChangedIndex)
                sectionCount = projection.project(step.timeline).count
            }
        }
        XCTAssertGreaterThan(sectionCount, 0)
    }

    /// Steady-state streaming: only tail entries change. This is the common
    /// case and should cost microseconds per event regardless of length.
    @MainActor
    func testIncrementalSectionProjectionTailOnlyPerformance() {
        let initial = makeTimeline(turnCount: 2_000)
        var timeline = initial
        var steps: [(timeline: [TimelineEntry], index: Int)] = []
        for event in 0..<120 {
            if event.isMultiple(of: 2) {
                timeline.append(
                    itemEntry(
                        id: "tail-item-\(event)",
                        kind: .commandExecution,
                        status: .inProgress,
                        turnID: "turn-1999"
                    )
                )
                steps.append((timeline, timeline.count - 1))
            } else {
                timeline[timeline.count - 1].item?.status = MaidItemStatus.completed.rawValue
                steps.append((timeline, timeline.count - 1))
            }
        }

        let projection = ChatTimelineProjection()
        _ = projection.project(initial)
        var sectionCount = 0

        measure(metrics: [XCTClockMetric()]) {
            for step in steps {
                projection.invalidate(from: step.index)
                sectionCount = projection.project(step.timeline).count
            }
        }
        XCTAssertGreaterThan(sectionCount, 0)
    }
}
