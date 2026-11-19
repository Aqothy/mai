#if DEBUG
    import Foundation

    /// A deterministic, daemon-free transcript for benchmarking the production
    /// chat timeline (`ChatView` → `ChatTimeline`).
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
                var answer = assistantAnswer(turn: turn)
                if UserDefaults.standard.bool(forKey: "ChatBenchmarkUniqueAnswers") {
                    answer = unique(answer, tag: "\(prefix)-\(turn)")
                }
                entries.append(
                    ThreadFixtures.entry(ref: "\(turnID)-assistant", kind: .assistantMessage, text: answer)
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
            case 0: ChatMarkdownFixtures.richBlocks
            case 1: ChatMarkdownFixtures.codeHeavy
            case 2: ChatMarkdownFixtures.componentCatalog
            case 3: ChatMarkdownFixtures.essay(wordCount: 600)
            case 4: ChatMarkdownFixtures.longMarkdown
            default:
                "Short answer for turn \(turn + 1): the fix lands in "
                    + "`ThreadStore.applyThreadEvent` and keeps the timeline "
                    + "buffer uniquely referenced while text streams."
            }
        }

        /// `-ChatBenchmarkUniqueAnswers YES`: every line of an answer carries
        /// `tag`, so no block repeats across turns or chats, as in real chats
        /// (the rotating fixtures otherwise repeat six answers, which flatters
        /// anything keyed by content).
        private static func unique(_ answer: String, tag: String) -> String {
            answer.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Fences, rules and setext underlines keep their meaning.
                if trimmed.isEmpty || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
                    || trimmed.allSatisfy({ "-*_= ".contains($0) })
                {
                    return String(line)
                }
                if trimmed.hasPrefix("|") {
                    // A table's delimiter row stays; a cell row tags its first cell.
                    if trimmed.allSatisfy({ "|:- ".contains($0) }) { return String(line) }
                    return String(line.replacing("|", with: "| \(tag)", maxReplacements: 1))
                }
                return line + " \(tag)"
            }.joined(separator: "\n")
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
