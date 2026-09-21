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
        private(set) var isFinished = false

        init(store: ThreadStore) {
            self.store = store
            characters = Array(
                (MockChatMarkdownFixtures.codeHeavy + "\n\n" + MockChatMarkdownFixtures.longMarkdown)
                    .prefix(20_000))
        }

        var sourceMatches: Bool {
            store.selectedThread?.timeline.last(where: { $0.message?.id == messageID })?.message?
                .text == String(characters)
                && store.selectedThread?.latestTurn?.completedAt != nil
        }

        func prepare() {
            send(.threadTurnStartRequested)
            send(
                .threadMessageSent, messageID: "synthetic-stream-user", role: .user,
                text: "Explain the implementation with code and tables.")
            send(
                .threadMessageSent, messageID: messageID, role: .assistant,
                text: String(characters.prefix(16)))
        }

        func run() async {
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
            // Include the settled renderer's transition in the measured interval.
            try? await Task.sleep(for: .seconds(1))
            isFinished = true
        }

        private func send(
            _ type: MaidEventType, messageID: String? = nil,
            role: MaidMessageRole? = nil, text: String? = nil, session: SessionBinding? = nil
        ) {
            sequence += 1
            let payload = EventPayload(
                approval: nil, attachments: nil, configOptions: nil,
                createdAt: nil, cwd: nil, decision: nil, item: nil, messageID: messageID,
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
