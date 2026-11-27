import CoreGraphics
import Foundation
import Testing

@testable import mai

/// Rows the builder makes for what the daemon sends: messages between
/// agents with their sender and body, a failed turn's header, the plan.
struct TranscriptRowRegressionTests {
    @Test func interAgentEnvelopePlanAndFailedTurnHeaderRenderCorrectly() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let env = Envelope(
            answers: nil, body: "Please check build logs.", covers: nil, delivery: nil,
            from: "Reviewer", kind: MaidEnvelopeKind.message.rawValue, thread: nil)
        let envEntry = EntryView(
            annotations: nil, at: base, attachments: nil, delivery: nil, detailAvailable: nil,
            envelope: env, kind: MaidItemKind.envelope.rawValue, ref: "env-1", request: nil,
            status: nil, text: nil, title: nil, tool: nil)
        let failedTool = ThreadFixtures.entry(ref: "tool-1", kind: .toolCall, status: .failed, title: "Run tests")
        let answer = ThreadFixtures.entry(ref: "a-1", kind: .assistantMessage, text: "Done.")
        let turn = ThreadFixtures.turn(
            id: "t1", participant: "p", state: .completed, startedAt: base,
            settledAt: base.addingTimeInterval(12), entries: [envEntry, failedTool, answer])
        let plan = [
            PlanEntry(content: "Fix geometry", priority: nil, status: "completed"),
            PlanEntry(content: "Verify benchmarks", priority: nil, status: "pending"),
        ]
        let builder = TranscriptBuilder(
            blocks: { _, _ in nil }, expandedTurnIDs: [], workingPhrase: "Thinking", plan: plan)
        let rows = builder.rows(for: [TranscriptTurn(turn)])

        let envelopeRow = rows.first { $0.id == "notice|t1|env-1" }
        #expect(envelopeRow?.kind == .notice(title: "From Reviewer", text: "Please check build logs."))

        let headerRow = rows.first { $0.id == "header|t1" }
        if case .turnHeader(let header)? = headerRow?.kind {
            #expect(header.title == "Worked for 12s · failed")
        } else {
            Issue.record("expected failed turn header")
        }

        let planRow = rows.first { $0.id == "plan" }
        #expect(planRow?.kind == .notice(title: "Plan", text: "✓ Fix geometry\n○ Verify benchmarks"))
    }

    /// CommonMark §5.3: a link reference definition after a blank line is not a
    /// block, so a 1-item list stays tight unless a real block follows it.
    @Test func linkDefinitionAfterBlankLineKeepsListTight() {
        let tight = MarkdownPlanner.blocks(from: "- foo\n\n  [a]: /url")
        if case .list(let list)? = tight.first {
            #expect(list.isTight)
        } else {
            Issue.record("expected tight list")
        }

        let loose = MarkdownPlanner.blocks(from: "- foo\n\n  [a]: /url\n  bar")
        if case .list(let list)? = loose.first {
            #expect(!list.isTight)
        } else {
            Issue.record("expected loose list when a second paragraph follows")
        }

        let defOnlyFirstItemTight = MarkdownPlanner.blocks(from: "- [a]: /url\n\n  bar")
        if case .list(let list)? = defOnlyFirstItemTight.first {
            #expect(list.isTight)
        } else {
            Issue.record("expected tight list when only one real block follows a link def")
        }

        let blankBetweenItemsLoose = MarkdownPlanner.blocks(from: "- [a]: /url\n\n- bar")
        if case .list(let list)? = blankBetweenItemsLoose.first {
            #expect(!list.isTight)
        } else {
            Issue.record("expected loose list when a blank line separates two items")
        }
    }

    /// Live `.reasoning` deltas streamed via `ThreadStore.streamingText` must
    /// flow through `TranscriptController`'s stream pipeline instead of freezing
    /// after the first chunk.
    @Test func reasoningTextDeltasStreamLiveThroughTranscriptController() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let summary = ThreadFixtures.summary(
            id: "synthetic-benchmark-reasoning", title: "Reasoning", cwd: "/tmp",
            agent: ("a", "A"), status: .running, createdAt: base, updatedAt: base)
        let turn = ThreadFixtures.turn(
            id: "t1", participant: summary.participants[0].id, state: .running,
            startedAt: base, settledAt: nil,
            entries: [ThreadFixtures.entry(ref: "r1", kind: .reasoning, text: "First", status: .inProgress)])
        let detail = ThreadFixtures.detail(summary: summary, turns: [turn])
        let store = ThreadStore(previewThreads: [summary], selectedThread: detail)
        let controller = TranscriptController(configuration: .testing)
        controller.columnWidth = 500
        controller.start(store: store, threadID: detail.id)

        // First delta creates ThreadStreamingText; second delta appends to it
        // without publishing a structural invalidation.
        let delta1 = ThreadEvent(
            delivery: nil, entry: nil, kind: MaidThreadEventKind.text.rawValue,
            participant: nil, plan: nil, request: nil, resolved: nil,
            seq: detail.seq + 1, summary: nil,
            text: TextAppend(entry: "r1", stream: "", text: " thought", turn: "t1"),
            thread: detail.id, turn: nil)
        let delta2 = ThreadEvent(
            delivery: nil, entry: nil, kind: MaidThreadEventKind.text.rawValue,
            participant: nil, plan: nil, request: nil, resolved: nil,
            seq: detail.seq + 2, summary: nil,
            text: TextAppend(entry: "r1", stream: "", text: " keeps streaming", turn: "t1"),
            thread: detail.id, turn: nil)
        store.applySyntheticBenchmarkEvent(delta1)
        try await Task.sleep(for: .milliseconds(20))
        store.applySyntheticBenchmarkEvent(delta2)

        // Tick frames until the stream releases and renders the live thought.
        for _ in 0..<40 {
            controller.frameDidTick()
            try await Task.sleep(for: .milliseconds(5))
            if controller.rows.contains(where: { row in
                if case .thought = row.kind,
                    let idx = controller.geometry.index(for: row.id),
                    controller.selectableText(ofRowAt: idx)?.contains("keeps streaming") == true
                {
                    return true
                }
                return false
            }) {
                break
            }
        }
        let thoughtIndex = try #require(controller.rows.firstIndex {
            if case .thought = $0.kind { return true }
            return false
        })
        #expect(controller.selectableText(ofRowAt: thoughtIndex) == "First thought keeps streaming")
    }
}
