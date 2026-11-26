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

        static func thread(
            turnCount: Int, identity: String = threadID,
            uniqueAnswers: Bool = UserDefaults.standard.bool(forKey: "ChatBenchmarkUniqueAnswers")
        ) -> ThreadDetail {
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
                if uniqueAnswers {
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

        /// A ~5 MB chat representing a long imported agent session: 40 finished
        /// turns with thoughts, tool steps, ~80 KB unique answers, and ~300 KB
        /// pasted prompts every 13th turn.
        static func largeThread(identity: String = "synthetic-benchmark-5mb") -> ThreadDetail {
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            let summary = ThreadFixtures.summary(
                id: identity, title: title, cwd: "/Users/example/Project", agent: ("synthetic", "Synthetic"),
                createdAt: base, updatedAt: base)
            let fixtures = [
                ChatMarkdownFixtures.longMarkdown, ChatMarkdownFixtures.codeHeavy, ChatMarkdownFixtures.richBlocks,
                ChatMarkdownFixtures.essay(wordCount: 2_000), ChatMarkdownFixtures.componentCatalog,
            ]
            let turns = (0..<40).map { turn -> TurnView in
                let turnID = "\(identity)-turn-\(turn)"
                let startedAt = base.addingTimeInterval(Double(turn) * 120)
                var answer = ""
                var index = turn
                while answer.utf8.count < 80_000 {
                    answer += fixtures[index % fixtures.count] + "\n\n"
                    index += 1
                }
                var prompt = userPrompt(turn: turn)
                if turn % 13 == 5 {
                    let line = "[2026-11-23 22:00:00] INFO worker=3 processed batch_id=987654321 duration_ms=12"
                    prompt += "\n\n" + (0..<3_700).map { "\(line) seq=\($0)" }.joined(separator: "\n")
                }
                var entries = [
                    ThreadFixtures.entry(ref: "\(turnID)-user", kind: .userMessage, text: prompt),
                    ThreadFixtures.entry(
                        ref: "\(turnID)-thought", kind: .reasoning,
                        text: unique(ChatMarkdownFixtures.essay(wordCount: 400), tag: "\(identity)-thought-\(turn)")),
                ]
                for step in 0..<3 { entries.append(toolEntry(turnID: turnID, turn: turn, step: step)) }
                entries.append(
                    ThreadFixtures.entry(
                        ref: "\(turnID)-assistant", kind: .assistantMessage, text: unique(answer, tag: "\(identity)-\(turn)")))
                return ThreadFixtures.turn(
                    id: turnID, participant: summary.participants[0].id, startedAt: startedAt,
                    settledAt: startedAt.addingTimeInterval(42), entries: entries)
            }
            return ThreadFixtures.detail(summary: summary, turns: turns)
        }

        /// Single-fixture threads for Phase 2 Step 1 giant-block measurements
        /// (`-ChatAutoBenchmark giant`).
        static func giantFixtureThreads() -> [(name: String, detail: ThreadDetail)] {
            giantFixtureCatalog().map { ($0.name, $0.build()) }
        }

        private static func giantFixtureCatalog() -> [(name: String, build: () -> ThreadDetail)] {
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            func makeThread(name: String, entries: [EntryView]) -> ThreadDetail {
                let id = "synthetic-benchmark-giant-\(name)"
                let summary = ThreadFixtures.summary(
                    id: id, title: "Giant \(name)", cwd: "/Users/example/Project",
                    agent: ("synthetic", "Synthetic"), createdAt: base, updatedAt: base)
                let turn = ThreadFixtures.turn(
                    id: "\(id)-turn-0", participant: summary.participants[0].id,
                    startedAt: base, settledAt: base.addingTimeInterval(5), entries: entries)
                return ThreadFixtures.detail(summary: summary, turns: [turn])
            }
            let paraUnit = "performance "
            return [
                (
                    "para-1mb",
                    {
                        let para1MB = String(repeating: paraUnit, count: 1_048_576 / paraUnit.utf8.count)
                        return makeThread(
                            name: "para-1mb",
                            entries: [
                                ThreadFixtures.entry(ref: "u", kind: .userMessage, text: "Show 1 MB paragraph."),
                                ThreadFixtures.entry(ref: "a", kind: .assistantMessage, text: para1MB),
                            ])
                    }
                ),
                (
                    "code-25k",
                    {
                        let code25k =
                            "```swift\n"
                            + (0..<25_000).map { "let value\($0) = compute(\($0), \"step\") // ok" }
                                .joined(separator: "\n")
                            + "\n```"
                        return makeThread(
                            name: "code-25k",
                            entries: [
                                ThreadFixtures.entry(ref: "u", kind: .userMessage, text: "Show 25,000-line code block."),
                                ThreadFixtures.entry(ref: "a", kind: .assistantMessage, text: code25k),
                            ])
                    }
                ),
                (
                    "code-1mb-line",
                    {
                        let code1MBLine =
                            "```json\n"
                            + String(repeating: #"{"k":"value","n":12345},"#, count: 1_048_576 / 24)
                            + "\n```"
                        return makeThread(
                            name: "code-1mb-line",
                            entries: [
                                ThreadFixtures.entry(ref: "u", kind: .userMessage, text: "Show 1 MB single code line."),
                                ThreadFixtures.entry(ref: "a", kind: .assistantMessage, text: code1MBLine),
                            ])
                    }
                ),
                (
                    "list-5000",
                    {
                        let list5000 = (0..<5_000).map { "- List item \($0) with details for rendering." }
                            .joined(separator: "\n")
                        return makeThread(
                            name: "list-5000",
                            entries: [
                                ThreadFixtures.entry(ref: "u", kind: .userMessage, text: "Show 5,000-item list."),
                                ThreadFixtures.entry(ref: "a", kind: .assistantMessage, text: list5000),
                            ])
                    }
                ),
                (
                    "list-item-1mb",
                    {
                        let listItem1MB = "- " + String(repeating: paraUnit, count: 1_048_576 / paraUnit.utf8.count)
                        return makeThread(
                            name: "list-item-1mb",
                            entries: [
                                ThreadFixtures.entry(ref: "u", kind: .userMessage, text: "Show 1 MB single list item."),
                                ThreadFixtures.entry(ref: "a", kind: .assistantMessage, text: listItem1MB),
                            ])
                    }
                ),
                (
                    "quote-500kb",
                    {
                        let quoteLine = "> Quoted analysis line with **bold** and `inline_code` for stress testing.\n"
                        let quote500KB = String(repeating: quoteLine, count: 500_000 / quoteLine.utf8.count)
                        return makeThread(
                            name: "quote-500kb",
                            entries: [
                                ThreadFixtures.entry(ref: "u", kind: .userMessage, text: "Show 500 KB blockquote."),
                                ThreadFixtures.entry(ref: "a", kind: .assistantMessage, text: quote500KB),
                            ])
                    }
                ),
                (
                    "user-500kb",
                    {
                        let logLine = "[2026-11-23 22:00:00] INFO worker=3 processed batch_id=987654321 duration_ms=12\n"
                        let user500KB = String(repeating: logLine, count: 500_000 / logLine.utf8.count)
                        return makeThread(
                            name: "user-500kb",
                            entries: [
                                ThreadFixtures.entry(ref: "u", kind: .userMessage, text: user500KB),
                            ])
                    }
                ),
            ]
        }

        /// A ~20 MB worst-case chat combining every extreme shape: 1 MB single
        /// paragraph, 1 MB single list item, 5,000-item list, 500 KB nested quote,
        /// 500 KB pasted user prompts, 500 KB reasoning traces, 50,000-line code
        /// dumps, 1 MB single horizontal JSON lines, BOM `U+FEFF`, and 80+ rich
        /// turns (`-ChatAutoBenchmark extreme`).
        static func extremeMegaThread(identity: String = "synthetic-benchmark-20mb") -> ThreadDetail {
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            let summary = ThreadFixtures.summary(
                id: identity, title: "Extreme 20 MB benchmark transcript", cwd: "/Users/example/Project",
                agent: ("synthetic", "Synthetic"), createdAt: base, updatedAt: base)
            let paraUnit = "performance analysis across large documents "
            let para1MB = "\u{FEFF}" + String(repeating: paraUnit, count: 1_048_576 / paraUnit.utf8.count)
            let code50k =
                "```swift\n"
                + (0..<50_000).map { "let item\($0) = process(index: \($0), tag: \"extreme\") // ok" }
                    .joined(separator: "\n")
                + "\n```"
            let code1MBLine =
                "```json\n"
                + String(repeating: #"{"id":12345,"status":"ok","payload":"abcdefgh"},"#, count: 1_048_576 / 48)
                + "\n```"
            let list5000 = (0..<5_000).map { "- Item \($0): detailed benchmark note with `code\($0)`." }
                .joined(separator: "\n")
            let listItem1MB = "- " + String(repeating: paraUnit, count: 1_048_576 / paraUnit.utf8.count)
            let quoteLine = "> Nested architectural summary with **emphasis** and `symbol`.\n"
            let quote500KB = String(repeating: quoteLine, count: 500_000 / quoteLine.utf8.count)
            let logLine = "[2026-11-25 13:00:00] INFO worker=4 batch=42 latency_ms=1.2 status=ok\n"
            let user500KB = String(repeating: logLine, count: 500_000 / logLine.utf8.count)
            let thought500KB = String(repeating: "Reasoning step: verifying invariants and layout bounds.\n\n", count: 8_500)

            let extremePayloads: [(prompt: String, thought: String, answer: String)] = [
                ("Paste 500 KB logs:\n\n" + user500KB, thought500KB, para1MB),
                ("Dump 50,000-line code file", "Checking code layout virtualization.", code50k),
                ("Dump 1 MB minified JSON on one line", "Checking horizontal 2D virtualization.", code1MBLine),
                ("Show 5,000-item list and 1 MB single list item", thought500KB, list5000 + "\n\n" + listItem1MB),
                ("Show 500 KB blockquote", "Checking quote bar continuity.", quote500KB),
            ]

            var turns: [TurnView] = []
            turns.reserveCapacity(80)
            // Interleave 75 rich ~150 KB turns + the 5 mega-payload turns (~20 MB total).
            let fixtures = [
                ChatMarkdownFixtures.longMarkdown, ChatMarkdownFixtures.codeHeavy, ChatMarkdownFixtures.richBlocks,
                ChatMarkdownFixtures.essay(wordCount: 2_000), ChatMarkdownFixtures.componentCatalog,
            ]
            for turn in 0..<80 {
                let turnID = "\(identity)-turn-\(turn)"
                let startedAt = base.addingTimeInterval(Double(turn) * 120)
                let prompt: String
                let thought: String
                let answer: String
                if turn >= 75 {
                    let payload = extremePayloads[turn - 75]
                    prompt = payload.prompt
                    thought = payload.thought
                    answer = payload.answer
                } else {
                    prompt = turn.isMultiple(of: 15) ? user500KB : userPrompt(turn: turn)
                    thought = unique(ChatMarkdownFixtures.essay(wordCount: 300), tag: "\(identity)-t-\(turn)")
                    var built = ""
                    var idx = turn
                    while built.utf8.count < 140_000 {
                        built += fixtures[idx % fixtures.count] + "\n\n"
                        idx += 1
                    }
                    answer = unique(built, tag: "\(identity)-\(turn)")
                }
                let entries = [
                    ThreadFixtures.entry(ref: "\(turnID)-user", kind: .userMessage, text: prompt),
                    ThreadFixtures.entry(ref: "\(turnID)-thought", kind: .reasoning, text: thought),
                    ThreadFixtures.entry(ref: "\(turnID)-assistant", kind: .assistantMessage, text: answer),
                ]
                turns.append(
                    ThreadFixtures.turn(
                        id: turnID, participant: summary.participants[0].id, startedAt: startedAt,
                        settledAt: startedAt.addingTimeInterval(42), entries: entries))
            }
            return ThreadFixtures.detail(summary: summary, turns: turns)
        }

        /// Reproduces the remaining scenarios that can still briefly blank on
        /// cold fast scrollbar scrubs: >32 KB unparsed `.pendingMessage` turns,
        /// giant >32-cell Markdown tables, rapid 80-turn cold jumps that exhaust
        /// the 4 ms sync deadline, and a 20 KB single non-ASCII code line.
        static func blankingStressThread(identity: String = "synthetic-benchmark-blanking") -> ThreadDetail {
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            let summary = ThreadFixtures.summary(
                id: identity, title: "Blanking stress repro", cwd: "/Users/example/Project",
                agent: ("synthetic", "Synthetic"), createdAt: base, updatedAt: base)
            let giantTable: String = {
                var lines = [
                    "| Metric | Subsystem | Baseline | Current | Delta | Notes |",
                    "| --- | --- | ---: | ---: | ---: | --- |",
                ]
                for row in 0..<120 {
                    lines.append(
                        "| row_\(row) | layout_pass_\(row % 7) | \(120 + row) ms | \(18 + row % 11) ms | -\(80 + row % 15)% | verified cell \(row) |")
                }
                return lines.joined(separator: "\n")
            }()
            let giantNonASCIILine =
                "```json\n"
                + String(repeating: #"{"title":"日本語テスト","msg":"مرحبا بالعالم","tag":"👩🏽‍💻"},"#, count: 320)
                + "\n```"
            let fixtures = [
                ChatMarkdownFixtures.longMarkdown, ChatMarkdownFixtures.codeHeavy,
                ChatMarkdownFixtures.richBlocks, ChatMarkdownFixtures.componentCatalog,
            ]
            var turns: [TurnView] = []
            turns.reserveCapacity(95)
            for turn in 0..<95 {
                let turnID = "\(identity)-turn-\(turn)"
                let startedAt = base.addingTimeInterval(Double(turn) * 90)
                let prompt: String
                let answer: String
                if turn < 10 {
                    // Ten ~220 KB unparsed turns (> 32 KB sync parse limit).
                    prompt = "Blanking repro turn \(turn + 1): >32 KB unparsed message"
                    var built = "## Unparsed >32 KB Turn \(turn + 1)\n\n"
                    var idx = turn
                    while built.utf8.count < 220_000 {
                        built += fixtures[idx % fixtures.count] + "\n\n"
                        idx += 1
                    }
                    answer = unique(built, tag: "\(identity)-big-\(turn)")
                } else if turn == 10 {
                    prompt = "Blanking repro: 20 KB single non-ASCII code line"
                    answer = giantNonASCIILine
                } else if turn.isMultiple(of: 16) {
                    prompt = "Blanking repro: 120-row (720-cell) table (>32-cell sync limit)"
                    answer = "### Giant Table (Turn \(turn + 1))\n\n" + giantTable
                } else {
                    prompt = userPrompt(turn: turn)
                    answer = unique(assistantAnswer(turn: turn), tag: "\(identity)-fast-\(turn)")
                }
                let entries = [
                    ThreadFixtures.entry(ref: "\(turnID)-user", kind: .userMessage, text: prompt),
                    ThreadFixtures.entry(ref: "\(turnID)-assistant", kind: .assistantMessage, text: answer),
                ]
                turns.append(
                    ThreadFixtures.turn(
                        id: turnID, participant: summary.participants[0].id, startedAt: startedAt,
                        settledAt: startedAt.addingTimeInterval(20), entries: entries))
            }
            return ThreadFixtures.detail(summary: summary, turns: turns)
        }

        /// Lazy sidebar catalog for `-ChatDevExtremeThreads YES` (zero up-front
        /// payload allocation until the developer taps a thread in the sidebar).
        static func devExtremeThreads() -> [(summary: ThreadSummary, build: () -> ThreadDetail)] {
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            func summary(id: String, title: String, offset: TimeInterval) -> ThreadSummary {
                ThreadFixtures.summary(
                    id: id, title: title, cwd: "/Users/example/Project",
                    agent: ("synthetic", "Synthetic"),
                    createdAt: base.addingTimeInterval(offset),
                    updatedAt: base.addingTimeInterval(offset))
            }
            var catalog: [(ThreadSummary, () -> ThreadDetail)] = [
                (
                    summary(id: "synthetic-benchmark-blanking", title: "Blanking stress repro", offset: 1_100),
                    { blankingStressThread() }
                ),
                (
                    summary(id: "synthetic-benchmark-20mb", title: "Extreme 20 MB mega-chat", offset: 1_000),
                    { extremeMegaThread() }
                ),
                (
                    summary(id: "synthetic-benchmark-5mb", title: "Large 5 MB session (40 turns)", offset: 900),
                    { largeThread() }
                ),
                (
                    summary(id: threadID, title: "Synthetic 1,000 turns (unique)", offset: 800),
                    { thread(turnCount: 1_000, uniqueAnswers: true) }
                ),
            ]
            for (index, fixture) in giantFixtureCatalog().enumerated() {
                let id = "synthetic-benchmark-giant-\(fixture.name)"
                catalog.append((
                    summary(id: id, title: "Giant \(fixture.name)", offset: Double(700 - index * 50)),
                    fixture.build
                ))
            }
            return catalog
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
