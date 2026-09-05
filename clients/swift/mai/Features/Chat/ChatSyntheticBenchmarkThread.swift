#if DEBUG
    import Foundation

    /// A deterministic, daemon-free transcript for benchmarking the production
    /// chat timeline (`ChatView` → `ChatTimeline`), as opposed to the mock lab
    /// which drives only the row renderers.
    ///
    ///     -ChatPerformanceLab -ChatAutoBenchmark scroll -ChatBenchmarkSyntheticTurns 400
    ///
    /// Every turn is a finished agent turn: a user prompt, a thought, a few
    /// tool steps (folded behind the "Worked for" header exactly as in
    /// production), and a rich final answer. Final answers rotate through the
    /// heaviest fixtures — tables, fenced code, long Markdown, essays — so a
    /// sweep realizes the same row shapes that stutter in real chats.
    enum ChatSyntheticBenchmarkThread {
        nonisolated static let title = "Synthetic benchmark transcript"
        nonisolated static let threadID = "synthetic-benchmark-thread"

        static func thread(turnCount: Int) -> Thread {
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            var timeline: [TimelineEntry] = []
            timeline.reserveCapacity(turnCount * 6)

            for turn in 0..<turnCount {
                let turnID = "synthetic-turn-\(turn)"
                let startedAt = base.addingTimeInterval(Double(turn) * 120)
                let finishedAt = startedAt.addingTimeInterval(42)

                timeline.append(
                    messageEntry(
                        id: "\(turnID)-user",
                        role: .user,
                        turnID: turnID,
                        text: userPrompt(turn: turn),
                        at: startedAt
                    )
                )
                timeline.append(
                    reasoningEntry(turnID: turnID, turn: turn, at: startedAt)
                )
                for step in 0..<3 {
                    timeline.append(
                        toolEntry(
                            turnID: turnID,
                            turn: turn,
                            step: step,
                            at: startedAt.addingTimeInterval(Double(step + 1) * 5)
                        )
                    )
                }
                timeline.append(
                    messageEntry(
                        id: "\(turnID)-assistant",
                        role: .assistant,
                        turnID: turnID,
                        text: assistantAnswer(turn: turn),
                        at: finishedAt
                    )
                )
            }

            let lastTurnID = "synthetic-turn-\(max(0, turnCount - 1))"
            let latestTurn = Turn(
                completedAt: base.addingTimeInterval(Double(turnCount) * 120),
                error: nil,
                interruptRequested: false,
                requestedAt: base.addingTimeInterval(Double(turnCount - 1) * 120),
                startedAt: base.addingTimeInterval(Double(turnCount - 1) * 120),
                state: MaidTurnState.completed.rawValue,
                stopReason: nil,
                turnID: lastTurnID
            )
            return Thread(
                createdAt: base,
                cwd: "/Users/example/Project",
                id: threadID,
                latestTurn: latestTurn,
                modelSelection: nil,
                plan: nil,
                providerInstanceID: "synthetic",
                session: SessionBinding(
                    activeTurnID: nil,
                    configOptions: nil,
                    cwd: "/Users/example/Project",
                    driver: "synthetic",
                    lastError: nil,
                    providerInstanceID: "synthetic",
                    providerName: "Synthetic",
                    slashCommands: nil,
                    status: MaidSessionStatus.ready.rawValue,
                    stopRequested: false,
                    threadID: threadID,
                    tokenUsage: nil,
                    updatedAt: base
                ),
                timeline: timeline,
                title: title,
                updatedAt: base
            )
        }

        static func listEntry(for thread: Thread) -> ThreadListEntry {
            ThreadListEntry(
                createdAt: thread.createdAt,
                cwd: thread.cwd,
                hasPendingApprovals: false,
                id: thread.id,
                latestTurn: thread.latestTurn,
                modelSelection: nil,
                providerInstanceID: thread.providerInstanceID,
                session: thread.session,
                title: thread.title,
                updatedAt: thread.updatedAt
            )
        }

        // MARK: Content

        private static func userPrompt(turn: Int) -> String {
            "Turn \(turn + 1): explain the change, show the table of options, and "
                + "include the code we discussed for `module\(turn)`."
        }

        /// Rotates through the heaviest renderer shapes so every screenful of
        /// a sweep contains tables and fenced code.
        private static func assistantAnswer(turn: Int) -> String {
            switch turn % 6 {
            case 0: MockChatMarkdownFixtures.richBlocks
            case 1: MockChatMarkdownFixtures.codeHeavy
            case 2: MockChatMarkdownFixtures.componentCatalog
            case 3: MockChatMessage.essay(wordCount: 600)
            case 4: MockChatMarkdownFixtures.longMarkdown
            default:
                "Short answer for turn \(turn + 1): the fix lands in "
                    + "`ThreadStore.applyThreadEvent` and keeps the timeline "
                    + "buffer uniquely referenced while text streams."
            }
        }

        private static func messageEntry(
            id: String,
            role: MaidMessageRole,
            turnID: String,
            text: String,
            at date: Date
        ) -> TimelineEntry {
            TimelineEntry(
                approval: nil,
                item: nil,
                kind: MaidTimelineEntryKind.message.rawValue,
                message: Message(
                    attachments: nil,
                    createdAt: date,
                    id: id,
                    role: role.rawValue,
                    text: text,
                    turnID: turnID,
                    updatedAt: date
                )
            )
        }

        private static func reasoningEntry(
            turnID: String,
            turn: Int,
            at date: Date
        ) -> TimelineEntry {
            let text =
                "Considering the request for turn \(turn + 1). The **table** "
                    + "needs every option, and the code sample should compile "
                    + "against `module\(turn)` without touching the rest."
            return TimelineEntry(
                approval: nil,
                item: Item(
                    createdAt: date,
                    detailAvailable: false,
                    id: "\(turnID)-thought",
                    kind: MaidItemKind.reasoning.rawValue,
                    payload: JSONAny(["text": text]),
                    sequence: nil,
                    status: MaidItemStatus.completed.rawValue,
                    textDelta: nil,
                    title: nil,
                    toolCall: nil,
                    toolCallSummary: nil,
                    turnID: turnID,
                    updatedAt: date.addingTimeInterval(3)
                ),
                kind: MaidTimelineEntryKind.item.rawValue,
                message: nil
            )
        }

        private static func toolEntry(
            turnID: String,
            turn: Int,
            step: Int,
            at date: Date
        ) -> TimelineEntry {
            let summary = ToolCallSummary(
                action: MaidToolAction.execute.rawValue,
                attachmentCount: nil,
                attachments: nil,
                changeCount: nil,
                changes: nil,
                commandPreview: "swift build --target module\(turn) --step \(step)",
                cwd: "/Users/example/Project",
                durationMilliseconds: 1_200 + step * 300,
                errorPreview: nil,
                exitCode: 0,
                locationCount: nil,
                locations: nil,
                name: nil,
                namespace: nil,
                outputPreview: "Build complete! (\(step + 1).\(turn % 10)s)",
                providerKind: nil,
                queryPreview: nil,
                truncated: false
            )
            return TimelineEntry(
                approval: nil,
                item: Item(
                    createdAt: date,
                    detailAvailable: true,
                    id: "\(turnID)-tool-\(step)",
                    kind: MaidItemKind.commandExecution.rawValue,
                    payload: nil,
                    sequence: nil,
                    status: MaidItemStatus.completed.rawValue,
                    textDelta: nil,
                    title: nil,
                    toolCall: nil,
                    toolCallSummary: summary,
                    turnID: turnID,
                    updatedAt: date.addingTimeInterval(2)
                ),
                kind: MaidTimelineEntryKind.item.rawValue,
                message: nil
            )
        }
    }
#endif
