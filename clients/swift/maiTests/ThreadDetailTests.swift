import Foundation
import Testing
@testable import mai

/// The client's fold of a thread's events onto its snapshot. The daemon owns
/// what the events mean; these check that the fold keeps what it already had.
struct ThreadDetailTests {
    @Test
    func textFoldsOntoItsEntryEvenWhenItIsNotTheNewest() {
        var detail = makeDetail(turns: [
            ThreadFixtures.turn(id: "t1", state: .running, entries: [
                ThreadFixtures.entry(ref: "reply", kind: .assistantMessage, text: "Hel", status: .inProgress),
                ThreadFixtures.entry(ref: "tool", kind: .toolCall, status: .inProgress),
            ])
        ])

        let change = detail.apply(textEvent(seq: 2, turn: "t1", entry: "reply", text: "lo 👋🏽"))

        guard case .text(turnID: "t1", entryRef: "reply", delta: "lo 👋🏽") = change else {
            Issue.record("change = \(change)")
            return
        }
        #expect(detail.turns[0].entries.map(\.text) == ["Hello 👋🏽", nil])
    }

    @Test
    func anEntryReplacesTheOneWithItsRefAndOtherwiseAppends() {
        var detail = makeDetail(turns: [
            ThreadFixtures.turn(id: "t1", state: .running, entries: [
                ThreadFixtures.entry(ref: "a", kind: .toolCall, status: .inProgress),
                ThreadFixtures.entry(ref: "b", kind: .toolCall, status: .inProgress),
            ])
        ])
        let header = ThreadFixtures.turn(id: "t1", state: .running, entries: [])

        _ = detail.apply(ThreadFixtures.event(
            .entry, thread: "chat", seq: 2, turn: header,
            entry: ThreadFixtures.entry(ref: "a", kind: .toolCall, status: .completed, title: "Done")))
        _ = detail.apply(ThreadFixtures.event(
            .entry, thread: "chat", seq: 3, turn: header,
            entry: ThreadFixtures.entry(ref: "c", kind: .assistantMessage, text: "Next")))

        #expect(detail.turns[0].entries.map(\.ref) == ["a", "b", "c"])
        #expect(detail.turns[0].entries[0].itemStatus == .completed)
        #expect(detail.turns[0].entries[0].title == "Done")
    }

    /// Turn events carry the turn's header only; its entries stay.
    @Test
    func aTurnEventUpdatesTheHeaderAndKeepsTheEntries() {
        var detail = makeDetail(turns: [
            ThreadFixtures.turn(id: "t1", state: .running, entries: [
                ThreadFixtures.entry(ref: "reply", kind: .assistantMessage, text: "Answer")
            ])
        ])

        let change = detail.apply(ThreadFixtures.event(
            .turn, thread: "chat", seq: 2, turn: ThreadFixtures.turn(id: "t1", state: .completed, entries: [])))
        _ = detail.apply(ThreadFixtures.event(
            .turn, thread: "chat", seq: 3, turn: ThreadFixtures.turn(id: "t2", state: .running, entries: [])))

        guard case .turns(from: 0) = change else {
            Issue.record("change = \(change)")
            return
        }
        #expect(detail.turns.map(\.id) == ["t1", "t2"])
        #expect(detail.turns[0].turnState == .completed)
        #expect(detail.turns[0].entries.map(\.text) == ["Answer"])
        #expect(detail.runningTurn?.id == "t2")
    }

    /// A delivery waits in the queue until it is delivered or cancelled; a
    /// refused one stays to retry. The queue keeps the daemon's order.
    @Test
    func deliveriesWaitInPositionOrderUntilDeliveredOrCancelled() {
        var detail = makeDetail(turns: [])
        let start = Date(timeIntervalSince1970: 1_000)
        let deliveries: [(id: String, state: MaidDeliveryState, position: Double, createdAt: Date)] = [
            ("late", .queued, 2, start),
            ("early", .queued, 1, start.addingTimeInterval(5)),
            ("tie", .queued, 2, start.addingTimeInterval(-5)),
            ("early", .sending, 1, start.addingTimeInterval(5)),
            ("late", .refused, 2, start),
            ("tie", .delivered, 2, start.addingTimeInterval(-5)),
            ("gone", .queued, 0, start),
            ("gone", .cancelled, 0, start),
        ]
        var seq = 1
        var queues: [[String]] = []
        for delivery in deliveries {
            seq += 1
            _ = detail.apply(deliveryEvent(
                seq: seq, id: delivery.id, state: delivery.state, position: delivery.position,
                createdAt: delivery.createdAt))
            queues.append(detail.queue.map(\.id))
        }

        #expect(queues == [
            ["late"],
            ["early", "late"],
            ["early", "tie", "late"],
            ["early", "tie", "late"],
            ["early", "tie", "late"],
            ["early", "late"],
            ["gone", "early", "late"],
            ["early", "late"],
        ])
        #expect(detail.queue.map(\.deliveryState) == [.sending, .refused])
    }

    @Test
    func eventsAtOrBeforeTheSnapshotOrForAnotherThreadChangeNothing() {
        var detail = makeDetail(turns: [
            ThreadFixtures.turn(id: "t1", state: .running, entries: [
                ThreadFixtures.entry(ref: "reply", kind: .assistantMessage, text: "A", status: .inProgress)
            ])
        ], seq: 5)

        let replayed = detail.apply(textEvent(seq: 5, turn: "t1", entry: "reply", text: "B"))
        var foreign = textEvent(seq: 6, turn: "t1", entry: "reply", text: "C")
        foreign.thread = "other"
        let misrouted = detail.apply(foreign)

        guard case .none = replayed, case .none = misrouted else {
            Issue.record("changes = \(replayed), \(misrouted)")
            return
        }
        #expect(detail.turns[0].entries[0].text == "A")
        #expect(detail.seq == 5)
    }

    @Test
    func olderTurnsPrependWithoutDuplicatingLoadedOnes() {
        var detail = makeDetail(turns: [
            ThreadFixtures.turn(id: "t3", entries: []),
            ThreadFixtures.turn(id: "t4", entries: []),
        ])
        detail.older = "t3"

        detail.prepend(ThreadTurnsResult(older: "t1", turns: [
            ThreadFixtures.turn(id: "t2", entries: []),
            ThreadFixtures.turn(id: "t3", entries: []),
        ]))

        #expect(detail.turns.map(\.id) == ["t2", "t3", "t4"])
        #expect(detail.older == "t1")
    }

    @Test
    func childrenUpdateInPlaceAndNewOnesAppend() {
        var detail = makeDetail(turns: [])
        let child = ThreadFixtures.summary(id: "child", title: "Researching", status: .running, parent: "chat")

        _ = detail.apply(ThreadFixtures.event(.child, thread: "chat", seq: 2, summary: child))
        _ = detail.apply(ThreadFixtures.event(
            .child, thread: "chat", seq: 3,
            summary: ThreadFixtures.summary(id: "other", title: "Testing", parent: "chat")))
        _ = detail.apply(ThreadFixtures.event(
            .child, thread: "chat", seq: 4,
            summary: ThreadFixtures.summary(id: "child", title: "Researched", parent: "chat")))

        #expect(detail.children.map(\.id) == ["child", "other"])
        #expect(detail.children.map(\.title) == ["Researched", "Testing"])
        #expect(detail.children[0].threadStatus == .idle)
    }

    private func makeDetail(turns: [TurnView], seq: Int = 1) -> ThreadDetail {
        ThreadFixtures.detail(summary: ThreadFixtures.summary(id: "chat", title: "Chat"), turns: turns, seq: seq)
    }

    private func textEvent(seq: Int, turn: String, entry: String, text: String) -> ThreadEvent {
        ThreadFixtures.event(
            .text, thread: "chat", seq: seq, text: TextAppend(entry: entry, stream: "", text: text, turn: turn))
    }

    private func deliveryEvent(
        seq: Int, id: String, state: MaidDeliveryState, position: Double, createdAt: Date
    ) -> ThreadEvent {
        var event = ThreadFixtures.event(.delivery, thread: "chat", seq: seq)
        event.delivery = DeliveryView(
            annotations: nil, answers: nil, attachments: nil, createdAt: createdAt,
            from: ActorView(kind: "device", name: "You", participant: nil, thread: nil), id: id,
            kind: MaidDeliveryKind.prompt.rawValue, mode: MaidDeliveryMode.queue.rawValue, position: position,
            reason: nil, state: state.rawValue, text: id, to: "chat-agent", turn: nil
        )
        return event
    }
}
