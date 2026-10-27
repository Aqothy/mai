#if DEBUG
    import Foundation

    /// A deterministic, daemon-free transcript for benchmarking the production
    /// chat timeline (`ChatView` → `ChatTimeline`), as opposed to the mock lab
    /// which drives only the row renderers.
    ///
    ///     -ChatAutoBenchmark scroll -ChatBenchmarkSyntheticTurns 400
    ///
    /// Every turn is a finished agent turn: a user prompt, a thought, a few
    /// tool steps (folded behind the "Worked for" header exactly as in
    /// production), and a rich final answer. Final answers rotate through the
    /// heaviest fixtures — tables, fenced code, long Markdown, essays — so a
    /// sweep realizes the same row shapes that stutter in real chats.
    enum ChatSyntheticBenchmarkThread {
        nonisolated static let title = "Synthetic benchmark transcript"
        nonisolated static let threadID = "synthetic-benchmark-thread"

        static func thread(turnCount: Int, identity: String = threadID) -> ThreadDetail {
            let prefix = identity == threadID ? "synthetic" : identity
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            let summary = ThreadFixtures.summary(
                id: identity,
                title: title,
                cwd: "/Users/example/Project",
                agent: ("synthetic", "Synthetic"),
                createdAt: base,
                updatedAt: base
            )
            var turns: [TurnView] = []
            turns.reserveCapacity(turnCount)

            for turn in 0..<turnCount {
                let turnID = "\(prefix)-turn-\(turn)"
                let startedAt = base.addingTimeInterval(Double(turn) * 120)
                var entries = [
                    ThreadFixtures.entry(ref: "\(turnID)-user", kind: .userMessage, text: userPrompt(turn: turn)),
                    reasoningEntry(turnID: turnID, turn: turn),
                ]
                for step in 0..<3 {
                    entries.append(toolEntry(turnID: turnID, turn: turn, step: step))
                }
                entries.append(
                    ThreadFixtures.entry(ref: "\(turnID)-assistant", kind: .assistantMessage, text: assistantAnswer(turn: turn))
                )
                turns.append(
                    ThreadFixtures.turn(
                        id: turnID,
                        participant: summary.participants[0].id,
                        startedAt: startedAt,
                        settledAt: startedAt.addingTimeInterval(42),
                        entries: entries
                    ))
            }
            return ThreadFixtures.detail(summary: summary, turns: turns)
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

        private static func reasoningEntry(turnID: String, turn: Int) -> EntryView {
            let text =
                "Considering the request for turn \(turn + 1). The **table** "
                    + "needs every option, and the code sample should compile "
                    + "against `module\(turn)` without touching the rest."
            return ThreadFixtures.entry(ref: "\(turnID)-thought", kind: .reasoning, text: text)
        }

        private static func toolEntry(turnID: String, turn: Int, step: Int) -> EntryView {
            let summary = ToolCallSummary(
                action: nil,
                attachmentCount: nil,
                attachments: nil,
                background: nil,
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
                outputFormat: nil,
                outputPreview: "Build complete! (\(step + 1).\(turn % 10)s)",
                providerKind: nil,
                queryPreview: nil,
                truncated: false
            )
            return ThreadFixtures.entry(ref: "\(turnID)-tool-\(step)", kind: .commandExecution, tool: summary)
        }
    }
#endif
