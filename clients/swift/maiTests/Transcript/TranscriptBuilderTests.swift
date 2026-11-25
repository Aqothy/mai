import CoreGraphics
import Foundation
import Testing

@testable import mai

/// The fold and visibility rules, as `ChatTimelineLayoutTests` had them
/// (the rest of its cases are rewritten in Phase 2).
@MainActor
struct TranscriptBuilderTests {
    private func user(_ ref: String, text: String = "prompt") -> EntryView {
        ThreadFixtures.entry(ref: ref, kind: .userMessage, text: text)
    }

    private func assistant(_ ref: String, text: String = "answer") -> EntryView {
        ThreadFixtures.entry(ref: ref, kind: .assistantMessage, text: text)
    }

    private func item(_ ref: String, _ kind: MaidItemKind) -> EntryView {
        ThreadFixtures.entry(ref: ref, kind: kind, text: kind == .reasoning ? "thinking" : nil)
    }

    private func turn(_ id: String, _ state: MaidTurnState, _ entries: [EntryView]) -> TranscriptTurn {
        TranscriptTurn(ThreadFixtures.turn(id: id, state: state, entries: entries))
    }

    private func turn(_ id: String, _ entries: [EntryView]) -> TranscriptTurn {
        turn(id, .completed, entries)
    }

    /// Every message parsed to one paragraph, unless `pending`.
    private func rows(
        _ turns: [TranscriptTurn], expanded: Set<String> = [], pending: Set<String> = []
    ) -> [TranscriptRow] {
        TranscriptBuilder(
            blocks: { id, source in pending.contains(id) ? nil : [.paragraph([MarkdownInline(text: source)])] },
            expandedTurnIDs: expanded, workingPhrase: "Pondering…"
        ).rows(for: turns)
    }

    private func label(_ row: TranscriptRow) -> String {
        switch row.kind {
        case .userMessage: "user"
        case .markdownBlock: "message"
        case .pendingMessage: "pending"
        case .thought: "thought"
        case .activity: "activity"
        case .turnHeader: "header"
        case .turnActions: "actions"
        case .working: "working"
        case .notice: "notice"
        }
    }

    @Test func rowsGroupFoldAndKeepAttentionItemsVisible() {
        let cases: [(name: String, turns: [TranscriptTurn], expanded: Set<String>, kinds: [String])] = [
            ("consecutive activity groups",
             [turn("t1", .running, [user("m1"), item("i1", .toolCall), item("i2", .commandExecution),
                                    item("i3", .toolCall), assistant("m2")])],
             [], ["user", "header", "activity", "message", "working"]),
            ("reasoning stays outside groups while running",
             [turn("t1", .running, [user("m1"), item("i1", .reasoning), item("i2", .toolCall), assistant("m2")])],
             [], ["user", "header", "thought", "activity", "message", "working"]),
            ("reasoning folds once finished",
             [turn("t1", [user("m1"), item("i1", .reasoning), item("i2", .toolCall), assistant("m2")])],
             [], ["user", "header", "message", "actions"]),
            ("expanded finished turn shows intermediate messages",
             [turn("t1", [user("m1"), item("i1", .toolCall), assistant("m2"), item("i2", .commandExecution),
                          assistant("m3")])],
             ["t1"], ["user", "header", "activity", "message", "activity", "message", "actions"]),
            ("empty streamed message produces no row",
             [turn("t1", .running, [user("m1"), assistant("m2", text: ""), item("i1", .toolCall)])],
             [], ["user", "header", "activity", "working"]),
            ("previous turn folds while the next runs",
             [turn("t1", [user("m1"), item("i1", .toolCall), assistant("m2")]),
              turn("t2", .running, [user("m3"), item("i2", .toolCall)])],
             [], ["user", "header", "message", "actions", "user", "header", "activity", "working"]),
            ("whitespace-only reasoning does not split an activity group",
             [turn("t1", .running, [user("m1"), item("i1", .toolCall),
                                    ThreadFixtures.entry(ref: "r1", kind: .reasoning, text: " \n"),
                                    item("i2", .toolCall)])],
             [], ["user", "header", "activity", "working"]),
            ("warnings and errors never fold",
             [turn("t1", [item("i1", .toolCall), item("i2", .warning), item("i3", .error)])],
             [], ["header", "notice", "notice", "actions"]),
        ]
        for testCase in cases {
            let result = rows(testCase.turns, expanded: testCase.expanded)
            #expect(result.map(label) == testCase.kinds, "\(testCase.name)")
            #expect(Set(result.map(\.id)).count == result.count, "\(testCase.name)")
        }
    }

    /// A message shows as one estimated row until parsed, then as its blocks,
    /// both under the message's source so the reading place carries over.
    @Test func aMessageIsPendingUntilParsedAndKeepsItsSource() {
        let turns = [turn("t1", [user("m1"), assistant("m2", text: "One\n\nTwo")])]
        let pending = rows(turns, pending: ["t1|m2"])
        #expect(pending.map(label) == ["user", "pending", "actions"])
        #expect(pending[1].sourceID == "t1|m2")
        let parsed = TranscriptBuilder(
            blocks: { _, source in MarkdownPlanner.blocks(from: source) }, expandedTurnIDs: [], workingPhrase: ""
        ).rows(for: turns)
        #expect(parsed.map(\.id) == ["user|t1|m1", "t1|m2#0", "t1|m2#1", "actions|t1"])
        #expect(parsed.filter { $0.sourceID == "t1|m2" }.count == 2)
    }

    @Test func aTurnMaiDCutOffSaysSo() {
        let cutOff = TranscriptTurn(
            ThreadFixtures.turn(
                id: "t1", state: .interrupted, error: "maiD stopped while this turn ran.", entries: [user("m1")]))
        let result = rows([cutOff])
        #expect(result.map(label) == ["user", "notice", "actions"])
    }

    /// The running turn's header says "Working"; the last row says what the
    /// agent is up to instead of saying it again.
    @Test func aRunningTurnSaysWorkingOnce() {
        let rows = rows([turn("t", .running, [user("u"), item("a", .toolCall)])])
        var titles: [String] = []
        for row in rows {
            switch row.kind {
            case .turnHeader(let header): titles.append(header.title)
            case .working(let phrase): titles.append(phrase)
            default: break
            }
        }
        #expect(titles == ["Working", "Pondering…"])
    }

    /// User, assistant, and reasoning messages all unify through `.pendingMessage`
    /// -> off-main Markdown parsing -> laid-out Markdown (reasoning muted).
    @Test func userAssistantAndReasoningAllParseWholeOffMainAsMarkdown() async throws {
        let controller = TranscriptController(configuration: .launch)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 600, height: 600)
        host.controller = controller
        controller.attach(host)
        controller.openStarted = ContinuousClock.now.advanced(by: .seconds(60))

        let userSource = "[ref]: https://example.com/ref\n\nSee [ref] and **bold**."
        let thoughtSource = "Reasoning with *emphasis* and `code`."
        let assistantSource = "Final answer.\n\n```swift\nlet x = 1\n```"
        let userMsg = TranscriptMessage(kind: .user, turnID: "t1", ref: "u1")
        let thoughtMsg = TranscriptMessage(kind: .thought, turnID: "t1", ref: "r1")
        let assistantMsg = TranscriptMessage(kind: .assistant, turnID: "t1", ref: "a1")

        controller.setRows([
            userMsg.pendingRow(source: userSource),
            thoughtMsg.pendingRow(source: thoughtSource),
            assistantMsg.pendingRow(source: assistantSource),
        ])
        for _ in 0..<250 where controller.isAwaitingInitialEnd {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!controller.isAwaitingInitialEnd)
        #expect(controller.rows.map(\.id) == ["user|t1|u1", "thought|t1|r1", "t1|a1#0", "t1|a1#1"])

        // User message resolved reference link whole and laid out as a bubble.
        let expectedURL = try #require(URL(string: "https://example.com/ref"))
        if case .bubble(let userLayout, _, _, _, _) = controller.layout(forRowAt: 0)?.content {
            #expect(userLayout.string == "See ref and bold.")
            #expect(userLayout.links == [expectedURL])
        } else {
            Issue.record("expected laid-out user bubble")
        }

        // Reasoning rendered as Markdown with muted secondary color on all runs.
        if case .text(let thoughtLayout, _) = controller.layout(forRowAt: 1)?.content {
            #expect(thoughtLayout.string == "Reasoning with emphasis and code.")
            #expect(thoughtLayout.runs.allSatisfy { $0.color == .secondary })
        } else {
            Issue.record("expected laid-out muted thought text")
        }
    }
}
