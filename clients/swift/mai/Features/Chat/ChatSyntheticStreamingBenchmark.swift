#if DEBUG
    import Foundation

    /// Exercises the production reducer and its leaf-only streaming notifications,
    /// exclusively in the daemon-free synthetic thread.
    @MainActor
    final class ChatSyntheticStreamingBenchmark {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        private let store: ThreadStore
        private var sequence = 0
        private let turnID = "synthetic-stream-turn"
        private let messageID = "synthetic-stream-assistant"
        private let characters: [Character]
        private let includesActivity: Bool
        private let firstThought = String(
            String(repeating: "**Checking layout**\n\nKeep the thought, tool output and working row in the same frame. Preserve Unicode café 👩🏽‍💻 and partial `inline code` while the text wraps.\n\n", count: 50)
                .prefix(6_000))
        private let secondThought = String(
            String(repeating: "**Reviewing the result**\n\nThe tool has finished. Keep the next thought stable before the final answer begins.\n\n", count: 20)
                .prefix(1_600))
        private(set) var isFinished = false

        init(store: ThreadStore, includesActivity: Bool = false) {
            self.store = store
            self.includesActivity = includesActivity
            characters = Array(
                (MockChatMarkdownFixtures.codeHeavy + "\n\n" + MockChatMarkdownFixtures.longMarkdown)
                    .prefix(20_000))
        }

        var sourceMatches: Bool {
            let replyMatches = store.selectedThread?.timeline.last(where: { $0.message?.id == messageID })?.message?
                .text == String(characters)
                && store.selectedThread?.latestTurn?.completedAt != nil
            guard includesActivity else { return replyMatches }
            let items = store.selectedThread?.timeline.compactMap(\.item) ?? []
            let thoughtsMatch = [("first", firstThought), ("second", secondThought)].allSatisfy {
                name, expected in
                guard let item = items.first(where: { $0.id == "synthetic-stream-thought-\(name)" }),
                    let payload = item.payload?.value as? [String: Any]
                else { return false }
                return item.itemStatus == .completed && payload["text"] as? String == expected
            }
            let tool = items.first { $0.id == "synthetic-stream-tool" }
            return replyMatches && thoughtsMatch && tool?.itemStatus == .completed
                && tool?.toolCallSummary?.outputPreview == "QA output step 12 of 12"
        }

        func prepare() {
            send(.threadTurnStartRequested)
            send(
                .threadMessageSent, messageID: "synthetic-stream-user", role: .user,
                text: "Explain the implementation with code and tables.")
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
                send(
                    .threadMessageSent, messageID: messageID, role: .assistant,
                    text: String(characters[offset..<min(offset + 16, characters.count)]))
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
            var session = store.selectedThread?.session
            session?.activeTurnID = nil
            session?.status = MaidSessionStatus.ready.rawValue
            send(.threadSessionStatusSet, session: session)
            if includesActivity { traceActivity("turn-completed") }
            // Include the settled renderer's transition in the measured interval.
            try? await Task.sleep(for: .seconds(1))
            isFinished = true
        }

        private func prepareReply() {
            send(
                .threadMessageSent, messageID: messageID, role: .assistant,
                text: String(characters.prefix(16)))
        }

        private func streamThought(name: String, text: String, seeded: Bool) async -> Bool {
            let source = Array(text)
            if !seeded { sendThought(name: name, text: String(source.prefix(16))) }
            for offset in stride(from: 16, to: source.count, by: 40) {
                guard !Task.isCancelled else { return false }
                sendThought(name: name, delta: String(source[offset..<min(offset + 40, source.count)]))
                // Match the daemon's 50 ms reasoning flush rather than inventing
                // a render-only text path or an animation for this fixture.
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
            }
            sendThought(name: name, text: text, completed: true)
            return true
        }

        private func sendThought(
            name: String, text: String? = nil, delta: String? = nil, completed: Bool = false
        ) {
            send(.threadItemUpserted, item: Item(
                createdAt: .now, detailAvailable: false,
                id: "synthetic-stream-thought-\(name)", kind: MaidItemKind.reasoning.rawValue,
                payload: text.map { JSONAny(["text": $0]) }, sequence: nil,
                status: completed ? MaidItemStatus.completed.rawValue : MaidItemStatus.inProgress.rawValue,
                textDelta: delta, title: nil, toolCall: nil, toolCallSummary: nil,
                turnID: turnID, updatedAt: .now))
        }

        private func sendTool(step: Int, completed: Bool) -> Bool {
            guard var item = store.selectedThread?.timeline.compactMap(\.item)
                .first(where: { $0.itemKind == .commandExecution })
            else { return false }
            item.id = "synthetic-stream-tool"
            item.turnID = turnID
            item.createdAt = .now
            item.updatedAt = .now
            item.status = completed ? MaidItemStatus.completed.rawValue : MaidItemStatus.inProgress.rawValue
            item.toolCallSummary?.commandPreview = "printf 'QA tool output'"
            item.toolCallSummary?.outputPreview = "QA output step \(step) of 12"
            item.toolCallSummary?.exitCode = completed ? 0 : nil
            send(.threadItemUpserted, item: item)
            return true
        }

        private func traceActivity(_ phase: String) {
            ChatBenchmarkAutoRun.trace("activity phase=\(phase) unixTime=\(Date.now.timeIntervalSince1970)")
        }

        private func send(
            _ type: MaidEventType, messageID: String? = nil,
            role: MaidMessageRole? = nil, text: String? = nil, session: SessionBinding? = nil,
            item: Item? = nil
        ) {
            sequence += 1
            let payload = EventPayload(
                approval: nil, attachments: nil, configOptions: nil,
                createdAt: nil, cwd: nil, decision: nil, item: item, messageID: messageID,
                modelSelection: nil, optionID: nil, plan: nil, providerInstanceID: nil,
                requestID: nil, role: role?.rawValue, session: session, sessionCleared: nil,
                slashCommands: nil, stopReason: nil, text: text,
                threadID: ChatSyntheticBenchmarkThread.threadID, title: nil, tokenUsage: nil,
                turnID: turnID, updatedAt: nil, value: nil)
            store.applySyntheticBenchmarkEvent(
                Event(
                    actor: nil, commandID: nil,
                    eventID: "synthetic-stream-event-\(sequence)", metadata: nil, occurredAt: .now,
                    payload: payload, sequence: sequence, type: type.rawValue))
        }
    }
#endif
