import Foundation

/// A subscribed thread: the daemon's snapshot and the events after it.
///
/// The daemon owns every rule; this applies what each event says and
/// nothing else. Mutate it through its owner's storage
/// (`sessionsByID[id]?.detail?.apply(event)`): a temporary copy would give
/// `turns` a second reference and copy every entry on each streamed chunk.
nonisolated struct ThreadDetail {
    var seq: Int
    var summary: ThreadSummary
    var participants: [ParticipantView]
    /// Oldest first; `older` pages the turns before them.
    var turns: [TurnView]
    var older: String?
    /// Deliveries not yet delivered, in queue order.
    var queue: [DeliveryView]
    var requests: [RequestView]
    var children: [ThreadSummary]
    var plan: [PlanEntry]

    init(_ snapshot: ThreadSnapshot) {
        seq = snapshot.seq
        summary = snapshot.thread
        participants = snapshot.participants
        turns = snapshot.turns
        older = snapshot.older
        queue = snapshot.queue.sorted(by: Self.queueOrder)
        requests = snapshot.requests
        children = snapshot.children
        plan = snapshot.plan
    }

    var id: String { summary.id }

    /// What an event changed, so presentation redoes only that.
    enum Change: Equatable {
        /// A stale or unknown event.
        case none
        /// Text streamed onto an entry the turn already had.
        case text(turnID: String, entryRef: String, delta: String)
        /// Turns at or after this index changed.
        case turns(from: Int)
        /// Something besides the turns changed.
        case thread
        /// The thread's history changed under the subscriber; it subscribes
        /// again.
        case refresh
        case removed
    }

    mutating func apply(_ event: ThreadEvent) -> Change {
        guard event.thread == summary.id, event.seq > seq else { return .none }
        seq = event.seq
        switch MaidThreadEventKind(rawValue: event.kind) {
        case .entry:
            guard let turn = event.turn, let entry = event.entry else { return .none }
            let index = turnIndex(for: turn)
            if let at = turns[index].entries.lastIndex(where: { $0.ref == entry.ref }) {
                turns[index].entries[at] = entry
            } else {
                turns[index].entries.append(entry)
            }
            return .turns(from: index)
        case .text:
            guard let text = event.text,
                let index = turns.lastIndex(where: { $0.id == text.turn }),
                let at = turns[index].entries.lastIndex(where: { $0.ref == text.entry })
            else { return .none }
            turns[index].entries[at].text = (turns[index].entries[at].text ?? "") + text.text
            return .text(turnID: text.turn, entryRef: text.entry, delta: text.text)
        case .turn:
            guard let turn = event.turn else { return .none }
            return .turns(from: turnIndex(for: turn))
        case .delivery:
            guard let delivery = event.delivery else { return .none }
            queue.removeAll { $0.id == delivery.id }
            if Self.waits(delivery) {
                queue.append(delivery)
                queue.sort(by: Self.queueOrder)
            }
            return .thread
        case .request:
            guard let request = event.request else { return .none }
            if let at = requests.firstIndex(where: { $0.id == request.id }) {
                requests[at] = request
            } else {
                requests.append(request)
            }
            return .thread
        case .resolved:
            guard let resolved = event.resolved else { return .none }
            requests.removeAll { $0.id == resolved.request }
            return .thread
        case .participant:
            guard let participant = event.participant else { return .none }
            if let at = participants.firstIndex(where: { $0.id == participant.id }) {
                participants[at] = participant
            } else {
                participants.append(participant)
            }
            return .thread
        case .thread:
            guard let summary = event.summary else { return .none }
            self.summary = summary
            return .thread
        case .child:
            guard let child = event.summary else { return .none }
            if let at = children.firstIndex(where: { $0.id == child.id }) {
                children[at] = child
            } else {
                children.append(child)
            }
            return .thread
        case .plan:
            plan = event.plan ?? []
            return .thread
        case .refresh:
            return .refresh
        case .removed:
            return .removed
        case nil:
            return .none
        }
    }

    /// Prepends the page of turns before the oldest loaded one.
    mutating func prepend(_ page: ThreadTurnsResult) {
        let loaded = Set(turns.map(\.id))
        turns.insert(contentsOf: page.turns.filter { !loaded.contains($0.id) }, at: 0)
        older = page.older
    }

    /// The index of the event's turn with its new state, appending the turn
    /// when it is new. Entries come in their own events.
    private mutating func turnIndex(for turn: TurnView) -> Int {
        if let index = turns.lastIndex(where: { $0.id == turn.id }) {
            let entries = turns[index].entries
            turns[index] = turn
            turns[index].entries = entries
            return index
        }
        var added = turn
        added.entries = []
        turns.append(added)
        return turns.count - 1
    }

    /// Whether a delivery still waits in the queue: once delivered or
    /// cancelled it leaves.
    private static func waits(_ delivery: DeliveryView) -> Bool {
        switch MaidDeliveryState(rawValue: delivery.state) {
        case .queued, .sending, .refused: true
        case .delivered, .cancelled, nil: false
        }
    }

    private static func queueOrder(_ left: DeliveryView, _ right: DeliveryView) -> Bool {
        left.position != right.position ? left.position < right.position : left.createdAt < right.createdAt
    }
}

extension ThreadDetail {
    var status: MaidThreadStatus? { MaidThreadStatus(rawValue: summary.status) }

    /// The running turn, which the chat shows live.
    var runningTurn: TurnView? {
        turns.last { $0.turnState == .running }
    }

    var latestTurn: TurnView? { turns.last }

    /// The participant the composer talks to: the thread's address, else its
    /// first agent.
    var addressee: ParticipantView? {
        participants.first { $0.id == summary.address } ?? participants.first
    }

    func participant(_ id: String?) -> ParticipantView? {
        participants.first { $0.id == id }
    }

    /// A pending request or a delivery that didn't get through: the user
    /// must act before the chat moves on.
    var needsUser: Bool {
        !requests.isEmpty || queue.contains { $0.deliveryState == .refused }
    }
}

extension TurnView {
    nonisolated var turnState: MaidTurnState? { MaidTurnState(rawValue: state) }
}

extension EntryView {
    nonisolated var itemKind: MaidItemKind? { MaidItemKind(rawValue: kind) }
    nonisolated var itemStatus: MaidItemStatus? { status.flatMap(MaidItemStatus.init(rawValue:)) }
    nonisolated var envelopeKind: MaidEnvelopeKind? { envelope.flatMap { MaidEnvelopeKind(rawValue: $0.kind) } }
}

extension DeliveryView {
    nonisolated var deliveryState: MaidDeliveryState? { MaidDeliveryState(rawValue: state) }
    nonisolated var deliveryKind: MaidDeliveryKind? { MaidDeliveryKind(rawValue: kind) }
}

extension ThreadSummary {
    nonisolated var threadStatus: MaidThreadStatus? { MaidThreadStatus(rawValue: status) }
    nonisolated var holdReason: MaidHold? { hold.flatMap(MaidHold.init(rawValue:)) }
    nonisolated var originKind: MaidOriginKind? { MaidOriginKind(rawValue: origin.kind) }
}
