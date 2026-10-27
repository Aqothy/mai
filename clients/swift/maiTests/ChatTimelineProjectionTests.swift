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
        XCTAssertNil(released, "\(T.self) was not released synchronously")
    }

    @MainActor func testPresentationStateReleasesSynchronously() {
        assertSynchronousRelease { ChatTimelineProjection() }
        assertSynchronousRelease { ChatTextLayoutStore() }
        assertSynchronousRelease { ChatMarkdownSegmentCache() }
        assertSynchronousRelease { ChatAnnotationModel() }
        assertSynchronousRelease { ChatScrollState() }
        assertSynchronousRelease { ChatTimelineFoldModel() }
        assertSynchronousRelease { ThreadStreamingText(text: "Hello 👋🏽") }
        assertSynchronousRelease { JSONAny(["text": "Hello"]) }
        assertSynchronousRelease { JSONNull() }
    }
}

/// `ChatTimelineProjection` is the incremental section projection behind the
/// chat timeline; it must always agree with a full rebuild.
nonisolated
final class ChatTimelineProjectionTests: XCTestCase {
    @MainActor
    private func makeTurns(count: Int) -> [TurnView] {
        let response = String(repeating: "Wrapped prose for the fixture. ", count: 18)
        let start = Date(timeIntervalSince1970: 0)
        return (0..<count).map { turn in
            ThreadFixtures.turn(
                id: "turn-\(turn)",
                state: turn == count - 1 ? .running : .completed,
                startedAt: start.addingTimeInterval(Double(turn) * 60),
                settledAt: start.addingTimeInterval(Double(turn) * 60 + 42),
                entries: [
                    ThreadFixtures.entry(ref: "user-\(turn)", kind: .userMessage, text: "Question \(turn)?"),
                    ThreadFixtures.entry(ref: "assistant-\(turn)", kind: .assistantMessage, text: response),
                ] + (0..<3).map { item in
                    ThreadFixtures.entry(ref: "item-\(turn)-\(item)", kind: .commandExecution)
                })
        }
    }

    /// Simulated live events over `initial`: each mutated turn list plus the
    /// lowest turn index the session would report for it. The mix matches
    /// live agent traffic: entries appended to the running turn, its newest
    /// entry updating in place, a new turn starting, and (every fourth
    /// event) an older turn changing, as when a request resolves into it.
    @MainActor
    private func streamedSteps(
        initial: [TurnView],
        eventCount: Int
    ) -> [(turns: [TurnView], firstChangedIndex: Int)] {
        var turns = initial
        var steps: [(turns: [TurnView], firstChangedIndex: Int)] = []
        steps.reserveCapacity(eventCount)

        for event in 0..<eventCount {
            let last = turns.count - 1
            switch event % 4 {
            case 0:
                turns[last].entries.append(
                    ThreadFixtures.entry(ref: "streamed-\(event)", kind: .commandExecution, status: .inProgress))
                steps.append((turns, last))
            case 1:
                let newest = turns[last].entries.count - 1
                turns[last].entries[newest].status = MaidItemStatus.completed.rawValue
                turns[last].entries[newest].title = "Finished \(event)"
                steps.append((turns, last))
            case 2:
                turns[last].state = MaidTurnState.completed.rawValue
                turns.append(ThreadFixtures.turn(
                    id: "streamed-turn-\(event)", state: .running,
                    entries: [ThreadFixtures.entry(ref: "prompt-\(event)", kind: .userMessage, text: "Next \(event)")]))
                steps.append((turns, last))
            default:
                let index = turns.count / 2
                turns[index].entries.append(
                    ThreadFixtures.entry(ref: "warning-\(event)", kind: .warning, text: "Resolved \(event)"))
                steps.append((turns, index))
            }
        }
        return steps
    }

    /// Content-sensitive fingerprint, not just identity: a stale projection
    /// could keep identical row IDs while showing outdated statuses or text.
    @MainActor
    private func rowFingerprints(of sections: [ChatTimelineLayout.Section]) -> [String] {
        ChatTimelineLayout.rows(sections: sections, expandedSectionIDs: []).map { row -> String in
            switch row {
            case .message(let message):
                return "\(row.id)|\(message.text)"
            case .thought(let item), .notice(let item), .handoff(let item), .envelope(let item):
                return "\(row.id)|\(item.entry.status ?? "")|\(item.text ?? "")"
            case .activityGroup(let group):
                let items = group.items.map { "\($0.id):\($0.entry.status ?? ""):\($0.title ?? "")" }.joined(separator: ",")
                return "\(row.id)|\(items)"
            case .request(let request):
                return "\(row.id)|\(request.isOpen)|\(request.actionID ?? "none")"
            case .turnActivity(let activity):
                return "\(row.id)|\(activity.stepCount)|\(activity.isRunning)"
            case .turnFork(let fork):
                return "\(row.id)|\(fork.prompt?.id ?? "")"
            }
        }
    }

    // MARK: Correctness

    /// Locks the incremental projection to a full rebuild after every step:
    /// identical sections through appends, tail mutations, new turns, older
    /// turns changing, snapshot replacement, coalesced invalidations, and
    /// pure cache hits.
    @MainActor
    func testIncrementalProjectionMatchesFullRebuild() {
        let initial = makeTurns(count: 40)
        let projection = ChatTimelineProjection()

        var sections = projection.project(initial)
        XCTAssertEqual(rowFingerprints(of: sections), rowFingerprints(of: ChatTimelineLayout.sections(turns: initial)))

        var turns = initial
        for (step, event) in streamedSteps(initial: initial, eventCount: 120).enumerated() {
            turns = event.turns
            projection.invalidate(fromTurn: event.firstChangedIndex)
            sections = projection.project(event.turns)
            XCTAssertEqual(
                rowFingerprints(of: sections),
                rowFingerprints(of: ChatTimelineLayout.sections(turns: event.turns)),
                "Incremental projection diverged from a full rebuild at step \(step)"
            )

            // A snapshot or refresh replaces the turns; only a full
            // invalidation describes it.
            if step == 60 {
                var replaced = event.turns
                replaced.removeFirst(10)
                turns = replaced
                projection.invalidateAll()
                sections = projection.project(replaced)
                XCTAssertEqual(
                    rowFingerprints(of: sections),
                    rowFingerprints(of: ChatTimelineLayout.sections(turns: replaced))
                )
                // The stream goes on from its own turns, which replace these
                // again.
                projection.invalidateAll()
            }
        }

        // Several events may land before one body evaluation; the lowest
        // index wins.
        var coalesced = turns
        let last = coalesced.count - 1
        coalesced[last].entries[0].status = MaidItemStatus.failed.rawValue
        projection.invalidate(fromTurn: last)
        coalesced[5].entries[1].text = "Edited earlier message"
        projection.invalidate(fromTurn: 5)
        coalesced[last - 1].entries[0].status = MaidItemStatus.failed.rawValue
        projection.invalidate(fromTurn: last - 1)
        turns = coalesced
        sections = projection.project(coalesced)
        XCTAssertEqual(
            rowFingerprints(of: sections),
            rowFingerprints(of: ChatTimelineLayout.sections(turns: coalesced))
        )

        // Unchanged turns are a pure cache hit with identical output.
        let unchanged = projection.project(turns)
        XCTAssertEqual(rowFingerprints(of: unchanged), rowFingerprints(of: sections))
    }
}
