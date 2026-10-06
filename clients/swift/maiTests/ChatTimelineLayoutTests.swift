import Foundation
import Testing
#if os(macOS)
    import AppKit
#endif
@testable import mai

/// `ChatTimelineLayout` turns the wire timeline into the rows the chat List
/// renders: contiguous turn sections, compact activity groups, and the fold
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
        var timeline: [TimelineEntry] = []
        for index in 1...7 {
            let turnID = "turn-\(index)"
            timeline.append(
                userMessageEntry(id: "user-\(index)", turnID: turnID)
            )
            timeline.append(
                assistantMessageEntry(id: "assistant-\(index)", turnID: turnID)
            )
        }

        let sections = ChatTimelineLayout.sections(timeline: timeline)
        let firstPage = ChatTimelineLayout.paginatedSections(
            sections,
            userMessageLimit: 5
        )
        let secondPage = ChatTimelineLayout.paginatedSections(
            sections,
            userMessageLimit: 10
        )

        #expect(firstPage.map(\.id) == [
            "turn-3", "turn-4", "turn-5", "turn-6", "turn-7",
        ])
        #expect(secondPage.map(\.id) == sections.map(\.id))
    }

    // MARK: Grouping and folding

    @Test
    func rowsGroupFoldAndKeepAttentionItemsVisible() {
        let cases: [(name: String, timeline: [TimelineEntry], streaming: String?, expanded: Set<String>, kinds: [String])] = [
            ("consecutive activity groups",
             [userMessageEntry(id: "m1", turnID: "turn-1"),
              itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
              itemEntry(id: "i2", kind: .commandExecution, turnID: "turn-1"),
              itemEntry(id: "i3", kind: .toolCall, turnID: "turn-1"),
              assistantMessageEntry(id: "m2", turnID: "turn-1")],
             "turn-1", [], ["message", "turnActivity", "group", "message"]),
            ("reasoning stays outside groups while running",
             [userMessageEntry(id: "m1", turnID: "turn-1"),
              itemEntry(id: "i1", kind: .reasoning, turnID: "turn-1"),
              itemEntry(id: "i2", kind: .toolCall, turnID: "turn-1"),
              assistantMessageEntry(id: "m2", turnID: "turn-1")],
             "turn-1", [], ["message", "turnActivity", "thought", "group", "message"]),
            ("reasoning folds once finished",
             [userMessageEntry(id: "m1", turnID: "turn-1"),
              itemEntry(id: "i1", kind: .reasoning, turnID: "turn-1"),
              itemEntry(id: "i2", kind: .toolCall, turnID: "turn-1"),
              assistantMessageEntry(id: "m2", turnID: "turn-1")],
             nil, [], ["message", "turnActivity", "message"]),
            ("assistant message splits groups",
             [itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
              assistantMessageEntry(id: "m1", turnID: "turn-1"),
              itemEntry(id: "i2", kind: .toolCall, turnID: "turn-1")],
             "turn-1", [], ["turnActivity", "group", "message", "group"]),
            ("expanded finished turn shows intermediate segments",
             [userMessageEntry(id: "m1", turnID: "turn-1"),
              itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
              assistantMessageEntry(id: "m2", turnID: "turn-1"),
              itemEntry(id: "i2", kind: .commandExecution, turnID: "turn-1"),
              assistantMessageEntry(id: "m3", turnID: "turn-1")],
             nil, ["turn-1"], ["message", "turnActivity", "group", "message", "group", "message"]),
            ("empty streamed segment produces no row",
             [userMessageEntry(id: "m1", turnID: "turn-1"),
              messageEntry(id: "m2", role: .assistant, turnID: "turn-1", text: ""),
              itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1")],
             "turn-1", [], ["message", "turnActivity", "group"]),
            ("previous turn folds while the next runs",
             [userMessageEntry(id: "m1", turnID: "turn-1"),
              itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
              assistantMessageEntry(id: "m2", turnID: "turn-1"),
              userMessageEntry(id: "m3", turnID: "turn-2"),
              itemEntry(id: "i2", kind: .toolCall, turnID: "turn-2")],
             "turn-2", [], ["message", "turnActivity", "message", "message", "turnActivity", "group"]),
            ("steering prompt stays inside its turn",
             [userMessageEntry(id: "m1", turnID: "turn-1"),
              itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
              userMessageEntry(id: "m2", turnID: "turn-1"),
              itemEntry(id: "i2", kind: .toolCall, turnID: "turn-1")],
             "turn-1", [], ["message", "turnActivity", "group", "message", "group"]),
            // Restored history has no turn ids; user messages split sections.
            ("history without turn ids",
             [userMessageEntry(id: "m1", turnID: nil),
              itemEntry(id: "i1", kind: .toolCall, turnID: nil),
              assistantMessageEntry(id: "m2", turnID: nil),
              userMessageEntry(id: "m3", turnID: nil),
              itemEntry(id: "i2", kind: .toolCall, turnID: nil),
              assistantMessageEntry(id: "m4", turnID: nil)],
             nil, ["local-m3"], ["message", "turnActivity", "message", "message", "turnActivity", "group", "message"]),
            ("warnings and errors never fold",
             [itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
              itemEntry(id: "i2", kind: .warning, turnID: "turn-1"),
              itemEntry(id: "i3", kind: .error, turnID: "turn-1")],
             nil, [], ["turnActivity", "notice", "notice"]),
            ("pending approval stays visible",
             [approvalEntry(requestID: "r1", status: .pending, turnID: "turn-1")],
             nil, [], ["approval"]),
            ("resolved approval folds",
             [approvalEntry(requestID: "r1", status: .resolved, turnID: "turn-1")],
             nil, [], ["turnActivity"]),
        ]
        for testCase in cases {
            let result = rows(testCase.timeline, streaming: testCase.streaming, expanded: testCase.expanded)
            #expect(result.map(kindLabel) == testCase.kinds, "\(testCase.name)")
        }
        let grouped = rows(cases[0].timeline, streaming: "turn-1")
        #expect(activityGroup(grouped[2])?.items.map(\.id) == ["i1", "i2", "i3"])
        let folded = rows(cases[4].timeline, streaming: nil)
        #expect(folded.map(kindLabel) == ["message", "turnActivity", "message"])
        #expect(folded.last?.id == "message-m3")
        let previous = rows(cases[6].timeline, streaming: "turn-2")
        #expect(turnActivity(previous[1])?.isRunning == false)
        #expect(turnActivity(previous[4])?.isRunning == true)
    }

    /// The header appears as soon as the turn starts, before any activity.
    @Test
    func runningTurnShowsHeaderBeforeFirstActivity() {
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let result = rows(
            [userMessageEntry(id: "m1", turnID: "turn-1")],
            streaming: "turn-1",
            latestTurn: Turn(
                completedAt: nil, error: nil, interruptRequested: nil, requestedAt: startedAt,
                startedAt: startedAt, state: MaidTurnState.running.rawValue, stopReason: nil,
                turnID: "turn-1")
        )
        #expect(result.map(kindLabel) == ["message", "turnActivity"])
        #expect(turnActivity(result[1])?.isRunning == true)
        #expect(turnActivity(result[1])?.startedAt == startedAt)
    }

    // MARK: Turn header

    @Test
    func headerTitleReflectsDurationAndOutcome() {
        let start = Date(timeIntervalSince1970: 1_000)
        func turn(_ state: MaidTurnState, seconds: TimeInterval) -> Turn {
            Turn(
                completedAt: start.addingTimeInterval(seconds), error: nil, interruptRequested: nil,
                requestedAt: start, startedAt: start, state: state.rawValue, stopReason: nil,
                turnID: "turn-1")
        }
        let cases: [(timeline: [TimelineEntry], latestTurn: Turn?, title: String)] = [
            // The latest turn's own timestamps win.
            ([itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1")],
             turn(.completed, seconds: 65), "Worked for 1m 5s"),
            // Older turns derive a duration from their items.
            ([itemEntry(
                id: "i1", kind: .toolCall, turnID: "turn-1",
                createdAt: start, updatedAt: start.addingTimeInterval(42))],
             nil, "Worked for 42s"),
            ([itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
              itemEntry(id: "i2", kind: .toolCall, turnID: "turn-1")],
             nil, "Worked"),
            ([itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1", status: .interrupted)],
             turn(.interrupted, seconds: 12), "Stopped after 12s"),
            ([itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1", status: .interrupted)],
             nil, "Stopped"),
        ]
        for testCase in cases {
            let result = rows(testCase.timeline, streaming: nil, latestTurn: testCase.latestTurn)
            #expect(turnActivity(result[0])?.title == testCase.title)
            #expect(turnActivity(result[0])?.stepCount == testCase.timeline.count)
        }
    }

    @Test
    func stoppedOlderTurnKeepsItsOutcomeAfterLateToolCompletion() {
        let startedAt = Date(timeIntervalSince1970: 3_000)
        let result = rows(
            [
                // The provider finished the command after the stop.
                itemEntry(
                    id: "i1", kind: .commandExecution, turnID: "turn-1",
                    createdAt: startedAt, updatedAt: startedAt.addingTimeInterval(49)
                ),
                itemEntry(id: "i2", kind: .toolCall, turnID: "turn-2"),
            ],
            streaming: nil,
            latestTurn: Turn(
                completedAt: nil, error: nil, interruptRequested: nil,
                requestedAt: startedAt.addingTimeInterval(60), startedAt: startedAt.addingTimeInterval(60),
                state: MaidTurnState.completed.rawValue, stopReason: nil, turnID: "turn-2"
            ),
            previousTurns: [
                Turn(
                    completedAt: startedAt.addingTimeInterval(9), error: nil, interruptRequested: nil,
                    requestedAt: startedAt, startedAt: startedAt,
                    state: MaidTurnState.interrupted.rawValue, stopReason: nil, turnID: "turn-1"
                )
            ]
        )

        #expect(turnActivity(result[0])?.title == "Stopped after 9s")
    }

    @Test
    func headerFlagsFailedSteps() {
        let result = rows(
            [itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1", status: .failed)],
            streaming: nil
        )
        #expect(turnActivity(result[0])?.hasFailure == true)
    }

    // MARK: Summaries

    @Test
    func summarizesGroupedActivityFromStatedFacts() {
        func command(_ id: String, _ action: MaidToolAction? = nil) -> Item {
            makeItem(id: id, kind: .commandExecution, action: action)
        }
        func tool(
            _ id: String, _ name: String?, kind: MaidItemKind = .toolCall,
            action: MaidToolAction? = nil, namespace: String? = nil, title: String? = nil
        ) -> Item {
            makeItem(id: id, kind: kind, action: action, toolName: name, namespace: namespace, title: title)
        }
        let cases: [(name: String, items: [Item], summary: String)] = [
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
    _ timeline: [TimelineEntry],
    streaming: String?,
    expanded: Set<String> = [],
    latestTurn: Turn? = nil,
    previousTurns: [Turn] = []
) -> [ChatTimelineRowModel] {
    ChatTimelineLayout.rows(
        sections: ChatTimelineLayout.sections(timeline: timeline),
        streamingTurnID: streaming,
        latestTurn: latestTurn,
        previousTurns: previousTurns,
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
    case .approval: "approval"
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

private func userMessageEntry(id: String, turnID: String?) -> TimelineEntry {
    messageEntry(id: id, role: .user, turnID: turnID)
}

private func assistantMessageEntry(id: String, turnID: String?) -> TimelineEntry {
    messageEntry(id: id, role: .assistant, turnID: turnID)
}

func messageEntry(
    id: String,
    role: MaidMessageRole,
    turnID: String?,
    text: String = "text"
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

func itemEntry(
    id: String,
    kind: MaidItemKind,
    turnID: String?,
    status: MaidItemStatus = .completed,
    createdAt: Date = Date(timeIntervalSince1970: 0),
    updatedAt: Date = Date(timeIntervalSince1970: 0)
) -> TimelineEntry {
    TimelineEntry(
        approval: nil,
        item: makeItem(
            id: id,
            kind: kind,
            status: status,
            turnID: turnID,
            createdAt: createdAt,
            updatedAt: updatedAt
        ),
        kind: MaidTimelineEntryKind.item.rawValue,
        message: nil
    )
}

private func approvalEntry(
    requestID: String,
    status: MaidApprovalStatus,
    turnID: String?
) -> TimelineEntry {
    TimelineEntry(
        approval: Approval(
            args: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            decision: nil,
            optionID: nil,
            options: nil,
            requestID: requestID,
            status: status.rawValue,
            turnID: turnID,
            updatedAt: Date(timeIntervalSince1970: 0)
        ),
        item: nil,
        kind: MaidTimelineEntryKind.approval.rawValue,
        message: nil
    )
}

private func makeItem(
    id: String,
    kind: MaidItemKind,
    status: MaidItemStatus = .completed,
    action: MaidToolAction? = nil,
    toolName: String? = nil,
    namespace: String? = nil,
    title: String? = nil,
    turnID: String? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 0),
    updatedAt: Date = Date(timeIntervalSince1970: 0)
) -> Item {
    Item(
        createdAt: createdAt,
        detailAvailable: nil,
        id: id,
        kind: kind.rawValue,
        payload: nil,
        sequence: nil,
        status: status.rawValue,
        textDelta: nil,
        title: title,
        toolCall: nil,
        toolCallSummary: action == nil && toolName == nil
            ? nil
            : ToolCallSummary(
                action: action?.rawValue,
                attachmentCount: nil,
                attachments: nil,
                changeCount: nil,
                changes: nil,
                commandPreview: nil,
                cwd: nil,
                durationMilliseconds: nil,
                errorPreview: nil,
                exitCode: nil,
                locationCount: nil,
                locations: nil,
                name: toolName,
                namespace: namespace,
                outputPreview: nil,
                providerKind: nil,
                queryPreview: nil,
                truncated: nil
            ),
        turnID: turnID,
        updatedAt: updatedAt
    )
}
