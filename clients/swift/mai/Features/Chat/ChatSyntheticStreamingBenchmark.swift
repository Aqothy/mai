#if DEBUG
    import Foundation

    /// Exercises the production reducer and its leaf-only streaming notifications,
    /// exclusively in the daemon-free synthetic thread.
    @MainActor
    final class ChatSyntheticStreamingBenchmark {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        private let store: ThreadStore
        private let turnID = "synthetic-stream-turn"
        private let messageID = "synthetic-stream-assistant"
        private let characters: [Character]
        private let includesActivity: Bool
        // Unique section numbers make stale tiles distinguishable in recordings;
        // identical repeated paragraphs can hide a one-paragraph displacement.
        private let firstThought = String(
            (1...50).map { section in
                "**Checking layout \(section)**\n\nSection \(section) keeps the thought, tool output and working row in the same frame. Preserve Unicode café 👩🏽‍💻 and partial `inline code` while the text wraps.\n\n"
            }.joined()
                .prefix(6_000))
        private let secondThought = String(
            (1...20).map { section in
                "**Reviewing result \(section)**\n\nReview \(section): the tool has finished. Keep this thought stable before the final answer begins.\n\n"
            }.joined()
                .prefix(1_600))
        private(set) var isFinished = false

        init(store: ThreadStore, includesActivity: Bool = false) {
            self.store = store
            self.includesActivity = includesActivity
            characters = Array(
                (MockChatMarkdownFixtures.codeHeavy + "\n\n" + MockChatMarkdownFixtures.longMarkdown)
                    .prefix(20_000))
        }

        private var turn: TurnView? {
            store.selectedThread?.turns.last { $0.id == turnID }
        }

        private func entry(_ ref: String) -> EntryView? {
            turn?.entries.last { $0.ref == ref }
        }

        var sourceMatches: Bool {
            let replyMatches = entry(messageID)?.text == String(characters)
                && turn?.turnState?.isSettled == true
            guard includesActivity else { return replyMatches }
            let thoughtsMatch = [("first", firstThought), ("second", secondThought)].allSatisfy {
                name, expected in
                let thought = entry("synthetic-stream-thought-\(name)")
                return thought?.itemStatus == .completed && thought?.text == expected
            }
            let tool = entry("synthetic-stream-tool")
            return replyMatches && thoughtsMatch && tool?.itemStatus == .completed
                && tool?.tool?.outputPreview == "QA output step 12 of 12"
        }

        func prepare() {
            sendTurn(.running)
            sendEntry(ThreadFixtures.entry(
                ref: "synthetic-stream-user", kind: .userMessage,
                text: "Explain the implementation with code and tables."))
            if includesActivity {
                sendThought(name: "first", text: String(firstThought.prefix(16)))
                traceActivity("first-thought-start")
            } else {
                prepareReply()
            }
        }

        func run() async {
            if includesActivity {
                guard await streamThought(name: "first", text: firstThought, seeded: true) else { return }
                traceActivity("first-thought-completed")
                for step in 1...12 {
                    guard !Task.isCancelled, sendTool(step: step, completed: false) else { return }
                    if step == 1 { traceActivity("tool-start") }
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                }
                guard sendTool(step: 12, completed: true) else { return }
                traceActivity("tool-completed")
                guard await streamThought(name: "second", text: secondThought, seeded: false) else { return }
                traceActivity("second-thought-completed")
                prepareReply()
                traceActivity("reply-start")
            }
            for offset in stride(from: min(16, characters.count), to: characters.count, by: 16) {
                guard !Task.isCancelled else { return }
                sendText(messageID, String(characters[offset..<min(offset + 16, characters.count)]))
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
            sendTurn(.completed)
            if includesActivity { traceActivity("turn-completed") }
            // Include the settled renderer's transition in the measured interval.
            try? await Task.sleep(for: .seconds(1))
            isFinished = true
        }

        private func prepareReply() {
            sendEntry(ThreadFixtures.entry(
                ref: messageID, kind: .assistantMessage, text: String(characters.prefix(16)),
                status: .inProgress))
        }

        private func streamThought(name: String, text: String, seeded: Bool) async -> Bool {
            let source = Array(text)
            if !seeded { sendThought(name: name, text: String(source.prefix(16))) }
            for offset in stride(from: 16, to: source.count, by: 40) {
                guard !Task.isCancelled else { return false }
                sendText("synthetic-stream-thought-\(name)", String(source[offset..<min(offset + 40, source.count)]))
                // Match the daemon's 50 ms reasoning flush rather than inventing
                // a render-only text path or an animation for this fixture.
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
            }
            sendThought(name: name, text: text, completed: true)
            return true
        }

        private func sendThought(name: String, text: String, completed: Bool = false) {
            sendEntry(ThreadFixtures.entry(
                ref: "synthetic-stream-thought-\(name)", kind: .reasoning, text: text,
                status: completed ? .completed : .inProgress))
        }

        private func sendTool(step: Int, completed: Bool) -> Bool {
            guard var tool = store.selectedThread?.turns.lazy.flatMap(\.entries)
                .first(where: { $0.itemKind == .commandExecution })
            else { return false }
            tool.ref = "synthetic-stream-tool"
            tool.status = completed ? MaidItemStatus.completed.rawValue : MaidItemStatus.inProgress.rawValue
            tool.tool?.commandPreview = "printf 'QA tool output'"
            tool.tool?.outputPreview = "QA output step \(step) of 12"
            tool.tool?.exitCode = completed ? 0 : nil
            sendEntry(tool)
            return true
        }

        private func traceActivity(_ phase: String) {
            ChatBenchmarkAutoRun.trace("activity phase=\(phase) unixTime=\(Date.now.timeIntervalSince1970)")
        }

        /// Each event follows what the thread has seen.
        private var nextSeq: Int {
            (store.selectedThread?.seq ?? 0) + 1
        }

        private var turnView: TurnView {
            turn ?? ThreadFixtures.turn(id: turnID, state: .running, entries: [])
        }

        private func sendTurn(_ state: MaidTurnState) {
            var view = turnView
            view.entries = []
            view.state = state.rawValue
            view.settledAt = state == .running ? nil : .now
            apply(ThreadFixtures.event(.turn, thread: ChatSyntheticBenchmarkThread.threadID, seq: nextSeq, turn: view))
        }

        private func sendEntry(_ entry: EntryView) {
            var view = turnView
            view.entries = []
            apply(ThreadFixtures.event(
                .entry, thread: ChatSyntheticBenchmarkThread.threadID, seq: nextSeq, turn: view, entry: entry))
        }

        private func sendText(_ ref: String, _ text: String) {
            let append = TextAppend(entry: ref, stream: MaidStreamKind.assistant.rawValue, text: text, turn: turnID)
            apply(ThreadFixtures.event(.text, thread: ChatSyntheticBenchmarkThread.threadID, seq: nextSeq, text: append))
        }

        private func apply(_ event: ThreadEvent) {
            store.applySyntheticBenchmarkEvent(event)
        }
    }
#endif
