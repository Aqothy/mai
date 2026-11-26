import CoreGraphics
import Foundation
import Testing

@testable import mai

/// Rows the builder makes for what the daemon sends: messages between
/// agents with their sender and body, a failed turn's header, the plan.
@MainActor
struct TranscriptRowRegressionTests {
    @MainActor @Test func interAgentEnvelopePlanAndFailedTurnHeaderRenderCorrectly() {
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
}
