import Foundation
import Testing
@testable import mai

/// `ChatTimelineLayout` turns the wire timeline into the rows the chat List
/// renders: contiguous turn sections, compact activity groups, and the fold
/// that hides a finished turn's work behind a "Worked for Ns" header.
struct ChatTimelineLayoutTests {

    // MARK: Grouping

    @Test
    func groupsConsecutiveActivityItemsIntoOneRow() {
        let rows = ChatTimelineLayout.rows(
            timeline: [
                userMessageEntry(id: "m1", turnID: "turn-1"),
                itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
                itemEntry(id: "i2", kind: .commandExecution, turnID: "turn-1"),
                itemEntry(id: "i3", kind: .toolCall, turnID: "turn-1"),
                assistantMessageEntry(id: "m2", turnID: "turn-1"),
            ],
            streamingTurnID: "turn-1",
            latestTurn: nil,
            expandedSectionIDs: []
        )

        #expect(rows.map(kindLabel) == ["message", "turnActivity", "group", "message"])
        #expect(activityGroup(rows[2])?.items.map(\.id) == ["i1", "i2", "i3"])
    }

    /// Reasoning is prose, not a step: it renders as its own text row and
    /// never joins tool-call groups.
    @Test
    func reasoningRendersAsThoughtRowOutsideGroups() {
        let timeline = [
            userMessageEntry(id: "m1", turnID: "turn-1"),
            itemEntry(id: "i1", kind: .reasoning, turnID: "turn-1"),
            itemEntry(id: "i2", kind: .toolCall, turnID: "turn-1"),
            itemEntry(id: "i3", kind: .commandExecution, turnID: "turn-1"),
            assistantMessageEntry(id: "m2", turnID: "turn-1"),
        ]

        let running = ChatTimelineLayout.rows(
            timeline: timeline,
            streamingTurnID: "turn-1",
            latestTurn: nil,
            expandedSectionIDs: []
        )
        #expect(running.map(kindLabel) == [
            "message", "turnActivity", "thought", "group", "message",
        ])
        #expect(activityGroup(running[3])?.items.map(\.id) == ["i2", "i3"])

        let folded = ChatTimelineLayout.rows(
            timeline: timeline,
            streamingTurnID: nil,
            latestTurn: nil,
            expandedSectionIDs: []
        )
        #expect(folded.map(kindLabel) == ["message", "turnActivity", "message"])
    }

    @Test
    func assistantMessageSplitsActivityGroups() {
        let rows = ChatTimelineLayout.rows(
            timeline: [
                itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
                assistantMessageEntry(id: "m1", turnID: "turn-1"),
                itemEntry(id: "i2", kind: .toolCall, turnID: "turn-1"),
            ],
            streamingTurnID: "turn-1",
            latestTurn: nil,
            expandedSectionIDs: []
        )

        #expect(rows.map(kindLabel) == ["turnActivity", "group", "message", "group"])
        #expect(activityGroup(rows[1])?.items.map(\.id) == ["i1"])
        #expect(activityGroup(rows[3])?.items.map(\.id) == ["i2"])
    }

    // MARK: Folding

    @Test
    func finishedTurnFoldsActivityBehindHeader() {
        let timeline = [
            userMessageEntry(id: "m1", turnID: "turn-1"),
            itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
            itemEntry(id: "i2", kind: .commandExecution, turnID: "turn-1"),
            assistantMessageEntry(id: "m2", turnID: "turn-1"),
        ]

        let folded = ChatTimelineLayout.rows(
            timeline: timeline,
            streamingTurnID: nil,
            latestTurn: nil,
            expandedSectionIDs: []
        )
        #expect(folded.map(kindLabel) == ["message", "turnActivity", "message"])

        let expanded = ChatTimelineLayout.rows(
            timeline: timeline,
            streamingTurnID: nil,
            latestTurn: nil,
            expandedSectionIDs: ["turn-1"]
        )
        #expect(expanded.map(kindLabel) == ["message", "turnActivity", "group", "message"])
    }

    /// Once a turn finishes, only its final assistant message stays visible;
    /// intermediate segments fold along with the activity.
    @Test
    func foldedTurnKeepsOnlyFinalAssistantMessage() {
        let timeline = [
            userMessageEntry(id: "m1", turnID: "turn-1"),
            itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
            assistantMessageEntry(id: "m2", turnID: "turn-1"),
            itemEntry(id: "i2", kind: .commandExecution, turnID: "turn-1"),
            assistantMessageEntry(id: "m3", turnID: "turn-1"),
        ]

        let folded = ChatTimelineLayout.rows(
            timeline: timeline,
            streamingTurnID: nil,
            latestTurn: nil,
            expandedSectionIDs: []
        )
        #expect(folded.map(kindLabel) == ["message", "turnActivity", "message"])
        #expect(folded.last?.id == "message-m3")

        let expanded = ChatTimelineLayout.rows(
            timeline: timeline,
            streamingTurnID: nil,
            latestTurn: nil,
            expandedSectionIDs: ["turn-1"]
        )
        #expect(expanded.map(kindLabel) == [
            "message", "turnActivity", "group", "message", "group", "message",
        ])
    }

    /// A running turn shows a live header (the working timer) with all of
    /// its activity visible — nothing folds until the turn finishes.
    @Test
    func runningTurnShowsLiveHeaderAndUnfoldedActivity() {
        let rows = ChatTimelineLayout.rows(
            timeline: [
                userMessageEntry(id: "m1", turnID: "turn-1"),
                itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
            ],
            streamingTurnID: "turn-1",
            latestTurn: nil,
            expandedSectionIDs: []
        )

        #expect(rows.map(kindLabel) == ["message", "turnActivity", "group"])
        #expect(turnActivity(rows[1])?.isRunning == true)
    }

    /// The header appears as soon as the turn starts, before any activity.
    @Test
    func runningTurnShowsHeaderBeforeFirstActivity() {
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let rows = ChatTimelineLayout.rows(
            timeline: [userMessageEntry(id: "m1", turnID: "turn-1")],
            streamingTurnID: "turn-1",
            latestTurn: Turn(
                completedAt: nil,
                error: nil,
                interruptRequested: nil,
                requestedAt: startedAt,
                startedAt: startedAt,
                state: MaidTurnState.running.rawValue,
                stopReason: nil,
                turnID: "turn-1"
            ),
            expandedSectionIDs: []
        )

        #expect(rows.map(kindLabel) == ["message", "turnActivity"])
        #expect(turnActivity(rows[1])?.isRunning == true)
        #expect(turnActivity(rows[1])?.startedAt == startedAt)
    }

    /// Empty streamed segments must not become blank padded rows.
    @Test
    func emptyMessagesProduceNoRows() {
        let rows = ChatTimelineLayout.rows(
            timeline: [
                userMessageEntry(id: "m1", turnID: "turn-1"),
                messageEntry(id: "m2", role: .assistant, turnID: "turn-1", text: ""),
                itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
            ],
            streamingTurnID: "turn-1",
            latestTurn: nil,
            expandedSectionIDs: []
        )

        #expect(rows.map(kindLabel) == ["message", "turnActivity", "group"])
    }

    @Test
    func previousTurnFoldsWhileNextTurnRuns() {
        let rows = ChatTimelineLayout.rows(
            timeline: [
                userMessageEntry(id: "m1", turnID: "turn-1"),
                itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
                assistantMessageEntry(id: "m2", turnID: "turn-1"),
                userMessageEntry(id: "m3", turnID: "turn-2"),
                itemEntry(id: "i2", kind: .toolCall, turnID: "turn-2"),
            ],
            streamingTurnID: "turn-2",
            latestTurn: nil,
            expandedSectionIDs: []
        )

        #expect(rows.map(kindLabel) == [
            "message", "turnActivity", "message",
            "message", "turnActivity", "group",
        ])
        #expect(turnActivity(rows[1])?.isRunning == false)
        #expect(turnActivity(rows[4])?.isRunning == true)
    }

    /// A steering prompt is stamped with the running turn's id; it must not
    /// split the section or fold the activity that follows it.
    @Test
    func steeringMessageStaysInsideItsTurn() {
        let rows = ChatTimelineLayout.rows(
            timeline: [
                userMessageEntry(id: "m1", turnID: "turn-1"),
                itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
                userMessageEntry(id: "m2", turnID: "turn-1"),
                itemEntry(id: "i2", kind: .toolCall, turnID: "turn-1"),
            ],
            streamingTurnID: "turn-1",
            latestTurn: nil,
            expandedSectionIDs: []
        )

        #expect(rows.map(kindLabel) == [
            "message", "turnActivity", "group", "message", "group",
        ])
    }

    /// Restored history replays without turn ids; sections then split on user
    /// messages so each prompt/response pair still folds independently.
    @Test
    func historyWithoutTurnIDsSplitsOnUserMessages() {
        let rows = ChatTimelineLayout.rows(
            timeline: [
                userMessageEntry(id: "m1", turnID: nil),
                itemEntry(id: "i1", kind: .toolCall, turnID: nil),
                assistantMessageEntry(id: "m2", turnID: nil),
                userMessageEntry(id: "m3", turnID: nil),
                itemEntry(id: "i2", kind: .toolCall, turnID: nil),
                assistantMessageEntry(id: "m4", turnID: nil),
            ],
            streamingTurnID: nil,
            latestTurn: nil,
            expandedSectionIDs: ["local-m3"]
        )

        #expect(rows.map(kindLabel) == [
            "message", "turnActivity", "message",
            "message", "turnActivity", "group", "message",
        ])
    }

    @Test
    func warningsAndErrorsNeverFold() {
        let rows = ChatTimelineLayout.rows(
            timeline: [
                itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
                itemEntry(id: "i2", kind: .warning, turnID: "turn-1"),
                itemEntry(id: "i3", kind: .error, turnID: "turn-1"),
            ],
            streamingTurnID: nil,
            latestTurn: nil,
            expandedSectionIDs: []
        )

        #expect(rows.map(kindLabel) == ["turnActivity", "notice", "notice"])
    }

    @Test
    func pendingApprovalStaysVisibleAndResolvedApprovalFolds() {
        let pending = ChatTimelineLayout.rows(
            timeline: [
                approvalEntry(requestID: "r1", status: .pending, turnID: "turn-1")
            ],
            streamingTurnID: nil,
            latestTurn: nil,
            expandedSectionIDs: []
        )
        #expect(pending.map(kindLabel) == ["approval"])

        let resolved = ChatTimelineLayout.rows(
            timeline: [
                approvalEntry(requestID: "r1", status: .resolved, turnID: "turn-1")
            ],
            streamingTurnID: nil,
            latestTurn: nil,
            expandedSectionIDs: []
        )
        #expect(resolved.map(kindLabel) == ["turnActivity"])
    }

    // MARK: Turn header

    @Test
    func headerUsesLatestTurnTimestampsWhenAvailable() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let rows = ChatTimelineLayout.rows(
            timeline: [
                itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1")
            ],
            streamingTurnID: nil,
            latestTurn: Turn(
                completedAt: startedAt.addingTimeInterval(65),
                error: nil,
                interruptRequested: nil,
                requestedAt: startedAt,
                startedAt: startedAt,
                state: MaidTurnState.completed.rawValue,
                stopReason: nil,
                turnID: "turn-1"
            ),
            expandedSectionIDs: []
        )

        #expect(turnActivity(rows[0])?.title == "Worked for 1m 5s")
        #expect(turnActivity(rows[0])?.stepCount == 1)
    }

    @Test
    func headerDerivesDurationFromItemTimestampsForOlderTurns() {
        let createdAt = Date(timeIntervalSince1970: 500)
        let rows = ChatTimelineLayout.rows(
            timeline: [
                itemEntry(
                    id: "i1",
                    kind: .toolCall,
                    turnID: "turn-1",
                    createdAt: createdAt,
                    updatedAt: createdAt.addingTimeInterval(42)
                )
            ],
            streamingTurnID: nil,
            latestTurn: nil,
            expandedSectionIDs: []
        )

        #expect(turnActivity(rows[0])?.title == "Worked for 42s")
    }

    @Test
    func headerFallsBackToPlainTitleWhenDurationIsUnknown() {
        let rows = ChatTimelineLayout.rows(
            timeline: [
                itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1"),
                itemEntry(id: "i2", kind: .toolCall, turnID: "turn-1"),
            ],
            streamingTurnID: nil,
            latestTurn: nil,
            expandedSectionIDs: []
        )

        #expect(turnActivity(rows[0])?.title == "Worked")
    }

    @Test
    func interruptedTurnReadsStoppedInsteadOfWorked() {
        let startedAt = Date(timeIntervalSince1970: 3_000)
        let rows = ChatTimelineLayout.rows(
            timeline: [
                itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1", status: .interrupted)
            ],
            streamingTurnID: nil,
            latestTurn: Turn(
                completedAt: startedAt.addingTimeInterval(12),
                error: nil,
                interruptRequested: nil,
                requestedAt: startedAt,
                startedAt: startedAt,
                state: MaidTurnState.interrupted.rawValue,
                stopReason: nil,
                turnID: "turn-1"
            ),
            expandedSectionIDs: []
        )

        #expect(turnActivity(rows[0])?.title == "Stopped after 12s")
    }

    @Test
    func interruptedStepInOlderTurnAlsoReadsStopped() {
        let rows = ChatTimelineLayout.rows(
            timeline: [
                itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1", status: .interrupted)
            ],
            streamingTurnID: nil,
            latestTurn: nil,
            expandedSectionIDs: []
        )

        #expect(turnActivity(rows[0])?.title == "Stopped")
    }

    @Test
    func headerFlagsFailedSteps() {
        let rows = ChatTimelineLayout.rows(
            timeline: [
                itemEntry(id: "i1", kind: .toolCall, turnID: "turn-1", status: .failed)
            ],
            streamingTurnID: nil,
            latestTurn: nil,
            expandedSectionIDs: []
        )

        #expect(turnActivity(rows[0])?.hasFailure == true)
    }

    // MARK: Summaries

    @Test
    func summarizesGroupedActivityByVerb() {
        let group = ChatActivityGroup(items: [
            makeItem(id: "i1", kind: .toolCall, action: .read),
            makeItem(id: "i2", kind: .toolCall, action: .read),
            makeItem(id: "i3", kind: .commandExecution),
        ])

        #expect(group.summary == "Read 2 files, ran a command")
    }

    @Test
    func summarizesEditsAndSearches() {
        let group = ChatActivityGroup(items: [
            makeItem(id: "i1", kind: .fileChange),
            makeItem(id: "i2", kind: .fileChange),
            makeItem(id: "i3", kind: .toolCall, action: .search),
        ])

        #expect(group.summary == "Edited 2 files, searched")
    }

    @Test
    func summarizesSingleNamedTool() {
        let group = ChatActivityGroup(items: [
            makeItem(id: "i1", kind: .mcpToolCall, action: .other, toolName: "list_issues")
        ])

        #expect(group.summary == "Used list_issues")
    }

    @Test
    func durationFormatting() {
        #expect(ChatTurnActivity.formatted(.seconds(3)) == "3s")
        #expect(ChatTurnActivity.formatted(.seconds(60)) == "1m")
        #expect(ChatTurnActivity.formatted(.seconds(125)) == "2m 5s")
    }
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

private func messageEntry(
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

private func itemEntry(
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
        title: nil,
        toolCall: nil,
        toolCallSummary: action.map { action in
            ToolCallSummary(
                action: action.rawValue,
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
                namespace: nil,
                outputPreview: nil,
                providerKind: nil,
                queryPreview: nil,
                truncated: nil
            )
        },
        turnID: turnID,
        updatedAt: updatedAt
    )
}
