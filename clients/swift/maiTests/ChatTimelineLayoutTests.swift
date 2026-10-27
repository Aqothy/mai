import Foundation
import Testing
#if os(macOS)
    import AppKit
#endif
@testable import mai

/// `ChatTimelineLayout` turns a thread's turns into the rows the chat List
/// renders: one section per turn, compact activity groups, and the fold
/// that hides a finished turn's work behind a "Worked for Ns" header.
struct ChatTimelineLayoutTests {
    #if os(macOS)
        @Test @MainActor
        func macResolvedProseRunKeepsSelectionContentAndSemantics() async {
            let source = """
                [Resolved link][guide]

                ```swift
                let value = 42
                ```

                ---

                # Final heading

                > Final quote

                [guide]: https://example.com/guide
                """
            let plan = ChatMarkdownRenderPlanner.plan(from: source)
            let contents = ChatResolvedMarkdownRowPlanner.contents(in: plan)

            #expect(contents.count == 3)
            guard case .proseRun(let leadingProse) = contents.first,
                case .proseRun(let trailingProse) = contents.last
            else {
                Issue.record("Expected native prose runs around the code block")
                return
            }

            let store = ChatTextLayoutStore()
            await store.prepare(
                requests: [
                    ChatTextLayoutRequest(
                        id: "leading",
                        content: .rendered(leadingProse.text),
                        width: 700
                    ),
                    ChatTextLayoutRequest(
                        id: "trailing",
                        content: .rendered(trailingProse.text),
                        width: 700
                    ),
                ]
            )
            let leadingLayout = store.layout(
                id: "leading",
                content: .rendered(leadingProse.text),
                width: 700
            )
            let trailingLayout = store.layout(
                id: "trailing",
                content: .rendered(trailingProse.text),
                width: 700
            )

            #expect(leadingLayout.attributedString.string == "Resolved link")
            #expect(
                leadingLayout.attributedString.attribute(
                    .link,
                    at: 0,
                    effectiveRange: nil
                ) as? URL == URL(string: "https://example.com/guide")
            )
            #expect(
                trailingLayout.attributedString.string.contains(
                    "Final heading\n\nFinal quote"
                )
            )
            #expect(!trailingLayout.thematicBreakRects.isEmpty)
            #expect(!trailingLayout.quoteBarRects.isEmpty)
        }
    #endif

    /// Follow intent after sequences of native scroll, visibility and
    /// expansion signals.
    @Test
    func scrollIntentFollowsOnlyWhenTheReaderIsAtTheEnd() {
        typealias Step = (ChatScrollState) -> Void
        let userScroll: (Bool) -> Step = { active in { $0.noteUserScrollActivity(isActive: active) } }
        let endVisible: (Bool) -> Step = { visible in { $0.noteEndVisibility(visible) } }
        let away: Step = { $0.noteScrollAwayFromEnd() }
        let towardEnd: Step = { $0.noteScrollTowardEnd() }
        let returned: Step = { $0.noteScrollReturnedToEnd() }
        let expansion: Step = { $0.noteContentExpansion() }
        let cases: [(name: String, steps: [Step], follows: Bool, nearBottom: Bool)] = [
            ("jump to bottom during a gesture", [userScroll(true), { $0.requestScrollToBottom(animated: true) }], true, true),
            ("scroll away and release", [userScroll(true), endVisible(false), userScroll(false)], false, false),
            ("scroll ending at the end", [userScroll(true), endVisible(true), userScroll(false), returned], true, true),
            ("transient end visibility mid-gesture", [userScroll(true), endVisible(false), endVisible(true), userScroll(false)], false, true),
            ("keyboard toward end before reaching it", [away, towardEnd], false, false),
            ("keyboard toward end then reaching it", [away, towardEnd, endVisible(true)], true, true),
            ("content growth while following", [endVisible(false)], true, true),
            ("expansion", [expansion], false, true),
            ("expansion pushing the end away", [expansion, endVisible(false)], false, false),
            ("expansion with the end visible again", [expansion, endVisible(false), endVisible(true)], true, true),
            ("layout visibility after explicit scroll away", [away, endVisible(true)], false, true),
            ("explicit return after scroll away", [away, endVisible(true), returned], true, true),
        ]
        for testCase in cases {
            let state = ChatScrollState()
            testCase.steps.forEach { $0(state) }
            #expect(state.shouldFollowBottom == testCase.follows, "\(testCase.name)")
            #expect(state.isNearBottom == testCase.nearBottom, "\(testCase.name)")
        }
        let jump = ChatScrollState()
        jump.requestScrollToBottom(animated: true)
        #expect(jump.bottomScrollRequest.animated)
    }

    @Test
    func paginatesByCompleteUserTurns() {
        let turns = (1...7).map { index in
            turn("turn-\(index)", [user("user-\(index)"), assistant("assistant-\(index)")])
        }
        // A turn an agent's message started has no prompt; it rides along.
        let sections = ChatTimelineLayout.sections(turns: turns + [turn("turn-8", [assistant("reply")])])

        let firstPage = ChatTimelineLayout.paginatedSections(sections, userMessageLimit: 5)
        let secondPage = ChatTimelineLayout.paginatedSections(sections, userMessageLimit: 10)

        #expect(firstPage.map(\.id) == ["turn-3", "turn-4", "turn-5", "turn-6", "turn-7", "turn-8"])
        #expect(secondPage.map(\.id) == sections.map(\.id))
    }

    // MARK: Grouping and folding

    @Test
    func rowsGroupFoldAndKeepAttentionItemsVisible() {
        let cases: [(name: String, turns: [TurnView], expanded: Set<String>, kinds: [String])] = [
            ("consecutive activity groups",
             [turn("turn-1", .running, [user("m1"), item("i1", .toolCall), item("i2", .commandExecution),
                                        item("i3", .toolCall), assistant("m2")])],
             [], ["message", "turnActivity", "group", "message"]),
            ("reasoning stays outside groups while running",
             [turn("turn-1", .running, [user("m1"), item("i1", .reasoning), item("i2", .toolCall), assistant("m2")])],
             [], ["message", "turnActivity", "thought", "group", "message"]),
            ("reasoning folds once finished",
             [turn("turn-1", [user("m1"), item("i1", .reasoning), item("i2", .toolCall), assistant("m2")])],
             [], ["message", "turnActivity", "message", "fork"]),
            ("assistant message splits groups",
             [turn("turn-1", .running, [item("i1", .toolCall), assistant("m1"), item("i2", .toolCall)])],
             [], ["turnActivity", "group", "message", "group"]),
            ("expanded finished turn shows intermediate segments",
             [turn("turn-1", [user("m1"), item("i1", .toolCall), assistant("m2"), item("i2", .commandExecution),
                              assistant("m3")])],
             ["turn-1"], ["message", "turnActivity", "group", "message", "group", "message", "fork"]),
            ("empty streamed segment produces no row",
             [turn("turn-1", .running, [user("m1"), assistant("m2", text: ""), item("i1", .toolCall)])],
             [], ["message", "turnActivity", "group"]),
            ("previous turn folds while the next runs",
             [turn("turn-1", [user("m1"), item("i1", .toolCall), assistant("m2")]),
              turn("turn-2", .running, [user("m3"), item("i2", .toolCall)])],
             [], ["message", "turnActivity", "message", "fork", "message", "turnActivity", "group"]),
            ("steering prompt stays inside its turn",
             [turn("turn-1", .running, [user("m1"), item("i1", .toolCall), user("m2"), item("i2", .toolCall)])],
             [], ["message", "turnActivity", "group", "message", "group"]),
            ("warnings and errors never fold",
             [turn("turn-1", [item("i1", .toolCall), item("i2", .warning), item("i3", .error)])],
             [], ["turnActivity", "notice", "notice", "fork"]),
            ("an answered request folds into its turn",
             [turn("turn-1", [user("m1"), recordedRequest("r1"), assistant("m2")])],
             [], ["message", "turnActivity", "message", "fork"]),
            ("what other agents said never folds, the chat's instructions never show",
             [turn("turn-1", [envelope("e1", .message), envelope("e2", .instructions), item("i1", .toolCall),
                              envelope("e3", .handoff), assistant("m1")])],
             [], ["envelope", "turnActivity", "handoff", "message", "fork"]),
            ("running background task outlives its turn's fold",
             [turn("turn-1", [user("m1"), item("i1", .toolCall),
                              item("bg", .commandExecution, status: .inProgress, background: true),
                              item("i2", .toolCall), assistant("m2")])],
             [], ["message", "turnActivity", "group", "message", "fork"]),
            ("finished background task folds",
             [turn("turn-1", [user("m1"), item("i1", .toolCall),
                              item("bg", .commandExecution, status: .interrupted, background: true),
                              item("i2", .toolCall), assistant("m2")])],
             [], ["message", "turnActivity", "message", "fork"]),
        ]
        for testCase in cases {
            let result = rows(testCase.turns, expanded: testCase.expanded)
            #expect(result.map(kindLabel) == testCase.kinds, "\(testCase.name)")
            #expect(Set(result.map(\.id)).count == result.count, "\(testCase.name)")
        }
        let grouped = rows(cases[0].turns)
        #expect(activityGroup(grouped[2])?.items.map(\.ref) == ["i1", "i2", "i3"])
        let folded = rows(cases[4].turns)
        #expect(folded.map(kindLabel) == ["message", "turnActivity", "message", "fork"])
        #expect(folded[2].id == "message-turn-1|m3")
        let previous = rows(cases[6].turns)
        #expect(turnActivity(previous[1])?.isRunning == false)
        #expect(turnActivity(previous[5])?.isRunning == true)
        let background = rows(cases[11].turns)
        #expect(activityGroup(background[2])?.items.map(\.ref) == ["bg"])
    }

    /// A turn that just settled stays presented as running until its settled
    /// rows are prepared.
    @Test
    func liveTurnStaysUnfoldedUntilItsSettledRowsAreReady() {
        let turns = [turn("turn-1", [user("m1"), item("i1", .toolCall), assistant("m2")])]
        let live = ChatTimelineLayout.rows(
            sections: ChatTimelineLayout.sections(turns: turns), liveTurnID: "turn-1", expandedSectionIDs: [])
        #expect(live.map(kindLabel) == ["message", "turnActivity", "group", "message", "fork"])
        #expect(turnActivity(live[1])?.isRunning == true)
    }

    /// An open request shows at the end of its turn, or at the end of the
    /// chat when its turn isn't loaded; once its record joins the turn, the
    /// record shows instead of both.
    @Test
    func openRequestsShowAtTheEndOfTheirTurnOnce() {
        let turns = [
            turn("turn-1", [user("m1"), item("i1", .toolCall), assistant("m2")]),
            turn("turn-2", .running, [user("m3"), item("i2", .toolCall)]),
        ]
        let result = rows(turns, requests: [openRequest("r1", turn: "turn-1"), openRequest("r2", turn: "turn-2"),
                                            openRequest("r3", turn: "unloaded"), openRequest("r4", turn: nil)])
        #expect(result.map(\.id) == [
            "message-turn-1|m1", "activity-turn-1", "message-turn-1|m2", "request-r1", "fork-turn-1",
            "message-turn-2|m3", "activity-turn-2", "group-turn-2|i2", "request-r2",
            "request-r3", "request-r4",
        ])

        var recorded = turns
        recorded[1].entries.append(recordedRequest("r2"))
        let resolving = rows(recorded, requests: [openRequest("r2", turn: "turn-2")])
        #expect(resolving.filter { $0.id == "request-r2" }.count == 1)
        guard case .request(let request) = resolving.last else {
            Issue.record("rows = \(resolving.map(\.id))")
            return
        }
        #expect(!request.isOpen)
    }

    /// A settled turn ends with one fork row that edits its own prompt; a
    /// running turn has none. Refs repeat across turns of different sessions,
    /// so row IDs carry the turn.
    @Test
    func settledTurnsEndWithTheirForkRow() {
        let result = rows([
            turn("turn-1", .failed, [item("e1", .error)]),
            turn("turn-2", [user("m1", text: "retried prompt"), item("i1", .toolCall), assistant("m2")]),
            turn("turn-3", .running, [user("m1", text: "running prompt")]),
        ])
        let forks = result.compactMap { row -> ChatTurnFork? in
            if case .turnFork(let fork) = row { return fork }
            return nil
        }
        #expect(forks.map(\.turnID) == ["turn-1", "turn-2"])
        #expect(forks.map(\.prompt?.text) == [nil, "retried prompt"])
        let turn2Fork = result.firstIndex { $0.id == "fork-turn-2" }
        #expect(turn2Fork == result.firstIndex { $0.id == "message-turn-3|m1" }.map { $0 - 1 })
        #expect(Set(result.map(\.id)).count == result.count)
    }

    /// The header appears as soon as the turn starts, before any activity.
    @Test
    func runningTurnShowsHeaderBeforeFirstActivity() {
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let result = rows([turn("turn-1", .running, startedAt: startedAt, [user("m1")])])
        #expect(result.map(kindLabel) == ["message", "turnActivity"])
        #expect(turnActivity(result[1])?.isRunning == true)
        #expect(turnActivity(result[1])?.startedAt == startedAt)
    }

    // MARK: Turn header

    /// The turn's own start and settle times give the duration; an entry
    /// the provider finished after a stop doesn't change the outcome.
    @Test
    func headerTitleReflectsDurationAndOutcome() {
        let start = Date(timeIntervalSince1970: 1_000)
        let cases: [(state: MaidTurnState, seconds: TimeInterval, entries: [EntryView], title: String)] = [
            (.completed, 65, [item("i1", .toolCall)], "Worked for 1m 5s"),
            (.completed, 0.5, [item("i1", .toolCall), item("i2", .toolCall)], "Worked"),
            (.interrupted, 12, [item("i1", .toolCall, status: .interrupted)], "Stopped after 12s"),
            (.interrupted, 9, [item("i1", .commandExecution)], "Stopped after 9s"),
            (.completed, 0.5, [item("i1", .toolCall, status: .interrupted)], "Stopped"),
        ]
        for testCase in cases {
            let result = rows([turn(
                "turn-1", testCase.state, startedAt: start, settledAt: start.addingTimeInterval(testCase.seconds),
                testCase.entries)])
            #expect(turnActivity(result[0])?.title == testCase.title)
            #expect(turnActivity(result[0])?.stepCount == testCase.entries.count)
        }
    }

    @Test
    func headerFlagsFailedSteps() {
        let result = rows([turn("turn-1", [item("i1", .toolCall, status: .failed)])])
        #expect(turnActivity(result[0])?.hasFailure == true)
    }

    // MARK: Summaries

    @Test
    func summarizesGroupedActivityFromStatedFacts() {
        func command(_ id: String, _ action: MaidToolAction? = nil) -> ChatItem {
            makeItem(id: id, kind: .commandExecution, action: action)
        }
        func tool(
            _ id: String, _ name: String?, kind: MaidItemKind = .toolCall,
            action: MaidToolAction? = nil, namespace: String? = nil, title: String? = nil
        ) -> ChatItem {
            makeItem(id: id, kind: kind, action: action, toolName: name, namespace: namespace, title: title)
        }
        let cases: [(name: String, items: [ChatItem], summary: String)] = [
            ("codex read and search commands",
             [command("c1", .read), command("c2", .read), command("c3", .search),
              command("c4", .search), command("c5")],
             "Read files, searched, ran a command"),
            ("acp read and search kinds fall back to titles",
             [tool("a1", nil, action: .read, title: "Read main.go"),
              tool("a2", nil, action: .search, title: "Find needle"),
              tool("a3", nil, title: "Fetch https://example.com"),
              makeItem(id: "a4", kind: .fileChange), makeItem(id: "a5", kind: .fileChange)],
             "Read a file, searched, Fetch https://example.com, edited files"),
            ("claude built-ins",
             [tool("b1", "Read", action: .read), tool("b2", "Grep", action: .search),
              tool("b3", "Glob", action: .search), tool("b4", "WebFetch"), command("b5")],
             "Read a file, searched, WebFetch, ran a command"),
            ("mcp tools keep raw names, listed once",
             [tool("m1", "search_issues", kind: .mcpToolCall, namespace: "github"),
              tool("m2", "search_issues", kind: .mcpToolCall, namespace: "github"),
              tool("m3", "Read")],
             "github · search_issues, Read"),
            ("more than three tool names",
             [makeItem(id: "r1", kind: .reasoning),
              command("x1", .read), command("x2", .read), command("x3", .read), command("x4", .read),
              command("x5", .search), command("x6", .search), command("x7"),
              makeItem(id: "x8", kind: .fileChange), makeItem(id: "x9", kind: .fileChange),
              makeItem(id: "x10", kind: .fileChange),
              tool("t1", "WebFetch"), tool("t2", "list_issues", kind: .mcpToolCall, namespace: "github"),
              tool("t3", "Agent"), tool("t4", "Skill"), tool("t5", "Skill")],
             "Thought, read files, searched, ran a command, edited files, "
                + "WebFetch, github · list_issues, Agent, +1 more"),
            ("unnamed tool falls back to its kind",
             [makeItem(id: "u1", kind: .toolCall)], "tool_call"),
        ]
        for testCase in cases {
            #expect(
                ChatActivityGroup(items: testCase.items).summary == testCase.summary,
                "\(testCase.name)"
            )
        }
        #expect(ChatTurnActivity.formatted(.seconds(3)) == "3s")
        #expect(ChatTurnActivity.formatted(.seconds(60)) == "1m")
        #expect(ChatTurnActivity.formatted(.seconds(125)) == "2m 5s")
    }
}

private func rows(
    _ turns: [TurnView],
    requests: [RequestView] = [],
    expanded: Set<String> = []
) -> [ChatTimelineRowModel] {
    ChatTimelineLayout.rows(
        sections: ChatTimelineLayout.sections(turns: turns),
        requests: requests.map(ChatRequest.init(open:)),
        expandedSectionIDs: expanded
    )
}

// MARK: - Fixtures

private func kindLabel(_ row: ChatTimelineRowModel) -> String {
    switch row {
    case .message: "message"
    case .thought: "thought"
    case .turnActivity: "turnActivity"
    case .activityGroup: "group"
    case .notice: "notice"
    case .request: "request"
    case .handoff: "handoff"
    case .envelope: "envelope"
    case .turnFork: "fork"
    }
}

private func activityGroup(_ row: ChatTimelineRowModel) -> ChatActivityGroup? {
    if case .activityGroup(let group) = row { return group }
    return nil
}

private func turnActivity(_ row: ChatTimelineRowModel) -> ChatTurnActivity? {
    if case .turnActivity(let activity) = row { return activity }
    return nil
}

private func turn(_ id: String, _ entries: [EntryView]) -> TurnView {
    turn(id, .completed, entries)
}

private func turn(
    _ id: String,
    _ state: MaidTurnState,
    startedAt: Date = Date(timeIntervalSince1970: 0),
    settledAt: Date? = nil,
    _ entries: [EntryView]
) -> TurnView {
    ThreadFixtures.turn(id: id, state: state, startedAt: startedAt, settledAt: settledAt, entries: entries)
}

private func user(_ ref: String, text: String = "text") -> EntryView {
    ThreadFixtures.entry(ref: ref, kind: .userMessage, text: text)
}

private func assistant(_ ref: String, text: String = "text") -> EntryView {
    ThreadFixtures.entry(ref: ref, kind: .assistantMessage, text: text)
}

private func item(
    _ ref: String,
    _ kind: MaidItemKind,
    status: MaidItemStatus = .completed,
    background: Bool = false
) -> EntryView {
    makeItem(id: ref, kind: kind, status: status, background: background).entry
}

private func envelope(_ ref: String, _ kind: MaidEnvelopeKind) -> EntryView {
    var entry = ThreadFixtures.entry(ref: ref, kind: .envelope)
    entry.envelope = Envelope(
        answers: nil, body: "said", covers: nil, delivery: nil, from: "Reviewer", kind: kind.rawValue, thread: nil)
    return entry
}

private let ask = Request(
    actions: [RequestAction(decision: MaidApprovalDecision.accept.rawValue, id: "allow", label: "Allow", submit: nil)],
    details: nil, message: "Run tests?", questions: nil, url: nil)

private func openRequest(_ id: String, turn: String?) -> RequestView {
    RequestView(
        answering: nil, ask: ask, entry: nil, id: id, openedAt: Date(timeIntervalSince1970: 0), participant: "agent",
        turn: turn)
}

private func recordedRequest(_ id: String) -> EntryView {
    var entry = ThreadFixtures.entry(ref: "request:\(id)", kind: .request)
    entry.request = RequestRecord(action: "allow", answers: nil, ask: ask, request: id)
    return entry
}

private func makeItem(
    id: String,
    kind: MaidItemKind,
    status: MaidItemStatus = .completed,
    background: Bool = false,
    action: MaidToolAction? = nil,
    toolName: String? = nil,
    namespace: String? = nil,
    title: String? = nil
) -> ChatItem {
    let tool = action == nil && toolName == nil && !background
        ? nil
        : ToolCallSummary(
            action: action?.rawValue, attachmentCount: nil, attachments: nil, background: background ? true : nil,
            changeCount: nil, changes: nil, commandPreview: nil, cwd: nil, durationMilliseconds: nil,
            errorPreview: nil, exitCode: nil, locationCount: nil, locations: nil, name: toolName,
            namespace: namespace, outputFormat: nil, outputPreview: nil, providerKind: nil, queryPreview: nil,
            truncated: nil)
    return ChatItem(
        turnID: "turn-1",
        entry: ThreadFixtures.entry(ref: id, kind: kind, status: status, title: title, tool: tool))
}
