#if DEBUG
import Foundation

/// Builders for thread models with the fields previews, benchmarks and
/// tests care about; the rest take the values a fresh chat has.
enum ThreadFixtures {
    static func summary(
        id: String,
        title: String,
        cwd: String = "",
        agent: (instance: String, name: String) = ("claude-code", "Claude Code"),
        status: MaidThreadStatus = .idle,
        needsInput: Bool = false,
        failed: Bool = false,
        parent: String? = nil,
        children: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) -> ThreadSummary {
        let participant = ParticipantSummary(
            driver: agent.instance, id: "\(id)-agent", instance: agent.instance, model: nil, name: agent.name
        )
        return ThreadSummary(
            address: participant.id,
            attention: Attention(failed: failed, needsInput: needsInput, unread: false),
            children: children,
            createdAt: createdAt,
            hold: nil,
            id: id,
            origin: OriginSummary(
                acceptsInput: true, at: nil, brief: nil, by: nil, forkedFrom: nil,
                kind: (parent == nil ? MaidOriginKind.user : .spawn).rawValue, parent: parent
            ),
            participants: [participant],
            status: status.rawValue,
            title: title,
            updatedAt: updatedAt,
            workspace: Workspace(additionalDirectories: nil, cwd: cwd)
        )
    }

    static func participant(of summary: ThreadSummary, live: Bool = true) -> ParticipantView {
        let agent = summary.participants[0]
        return ParticipantView(
            access: nil, commands: [], driver: agent.driver, goal: nil, id: agent.id, instance: agent.instance,
            live: live, model: agent.model, name: agent.name, options: [], settings: [], skills: [], usage: nil
        )
    }

    static func turn(
        id: String,
        participant: String = "agent",
        state: MaidTurnState = .completed,
        startedAt: Date = .now,
        settledAt: Date? = nil,
        entries: [EntryView]
    ) -> TurnView {
        TurnView(
            entries: entries,
            error: nil,
            id: id,
            participant: participant,
            settledAt: state == .running ? nil : settledAt ?? startedAt,
            startedAt: startedAt,
            startedBy: MaidStartedBy.delivery.rawValue,
            state: state.rawValue,
            stopReason: nil
        )
    }

    static func entry(
        ref: String,
        kind: MaidItemKind,
        text: String? = nil,
        status: MaidItemStatus = .completed,
        title: String? = nil,
        tool: ToolCallSummary? = nil,
        attachments: [Attachment]? = nil,
        delivery: String? = nil
    ) -> EntryView {
        EntryView(
            annotations: nil, at: nil, attachments: attachments, delivery: delivery, detailAvailable: nil,
            envelope: nil, kind: kind.rawValue, ref: ref, request: nil, status: status.rawValue, text: text,
            title: title, tool: tool
        )
    }

    static func detail(summary: ThreadSummary, turns: [TurnView], seq: Int = 1) -> ThreadDetail {
        ThreadDetail(
            ThreadSnapshot(
                children: [], older: nil, participants: [participant(of: summary)], plan: [], queue: [],
                requests: [], seq: seq, thread: summary, turns: turns
            ))
    }

    static func event(
        _ kind: MaidThreadEventKind,
        thread: String,
        seq: Int,
        turn: TurnView? = nil,
        entry: EntryView? = nil,
        text: TextAppend? = nil,
        summary: ThreadSummary? = nil
    ) -> ThreadEvent {
        ThreadEvent(
            delivery: nil, entry: entry, kind: kind.rawValue, participant: nil, plan: nil, request: nil,
            resolved: nil, seq: seq, summary: summary, text: text, thread: thread, turn: turn
        )
    }
}
#endif
