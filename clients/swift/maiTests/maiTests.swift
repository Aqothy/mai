import Foundation
import Testing
@testable import mai

@MainActor
struct ThreadStoreTests {
    @Test
    func keepsFiveInactiveSubscriptionsAndCachesEvictedModel() async {
        let threadIDs = (0...6).map { "thread-\($0)" }
        let rpc = MockThreadRPCClient(threads: threadIDs.map { makeThread($0) })
        let store = ThreadStore(rpc: rpc)
        await store.start()

        for (index, threadID) in threadIDs.enumerated() {
            store.selectThread(threadID)
            await waitUntil {
                store.subscribedThreadIDs.contains(threadID)
            }
            if index > 0 {
                await Task.yield()
            }
        }

        #expect(store.selectedThreadID == "thread-6")
        #expect(store.inactiveSubscribedThreadIDs == Set(threadIDs[1...5]))
        #expect(store.subscribedThreadIDs == Set(threadIDs[1...6]))
        #expect(store.cachedThreadIDs == Set(threadIDs))
        #expect(rpc.unsubscribedThreadIDs == ["thread-0"])
        #expect(rpc.subscriptionInputs.map(\.threadID) == threadIDs)
    }

    @Test
    func hiddenRunningThreadIsProtectedOutsideIdleBudget() async {
        let running = makeThread("running", isRunning: true)
        let idleThreads = (0...5).map { makeThread("idle-\($0)") }
        let rpc = MockThreadRPCClient(threads: [running] + idleThreads)
        let store = ThreadStore(rpc: rpc)
        await store.start()

        store.selectThread("running")
        await waitUntil { store.subscribedThreadIDs.contains("running") }
        for thread in idleThreads {
            store.selectThread(thread.id)
            await waitUntil { store.subscribedThreadIDs.contains(thread.id) }
        }

        #expect(store.protectedSubscribedThreadIDs == ["running"])
        #expect(store.inactiveSubscribedThreadIDs.count == 5)
        #expect(store.subscribedThreadIDs.count == 7)
        #expect(!rpc.unsubscribedThreadIDs.contains("running"))
    }

    @Test
    func inactiveSubscriptionExpiresAfterThirtyMinutes() async {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let rpc = MockThreadRPCClient(threads: [makeThread("a"), makeThread("b")])
        let store = ThreadStore(rpc: rpc, now: { currentDate })
        await store.start()

        store.selectThread("a")
        await waitUntil { store.subscribedThreadIDs.contains("a") }
        store.selectThread("b")
        await waitUntil { store.subscribedThreadIDs.contains("b") }
        #expect(store.inactiveSubscribedThreadIDs == ["a"])

        currentDate = currentDate.addingTimeInterval(30 * 60 - 1)
        store.performSubscriptionMaintenance(at: currentDate)
        #expect(store.inactiveSubscribedThreadIDs == ["a"])

        currentDate = currentDate.addingTimeInterval(2)
        store.performSubscriptionMaintenance(at: currentDate)
        await Task.yield()

        #expect(!store.subscribedThreadIDs.contains("a"))
        #expect(store.cachedThreadIDs.contains("a"))
        #expect(rpc.unsubscribedThreadIDs.contains("a"))
    }

    @Test
    func reopeningUnsubscribedThreadUsesCachedModelThenFreshSnapshot() async {
        let threadIDs = (0...6).map { "thread-\($0)" }
        let rpc = MockThreadRPCClient(threads: threadIDs.map { makeThread($0) })
        let store = ThreadStore(rpc: rpc)
        await store.start()

        for threadID in threadIDs {
            store.selectThread(threadID)
            await waitUntil { store.subscribedThreadIDs.contains(threadID) }
        }
        #expect(!store.subscribedThreadIDs.contains("thread-0"))
        #expect(store.cachedThreadIDs.contains("thread-0"))

        let subscriptionCount = rpc.subscriptionInputs.count
        store.selectThread("thread-0")
        #expect(store.selectedThread?.id == "thread-0")
        await waitUntil { rpc.subscriptionInputs.count == subscriptionCount + 1 }
        await waitUntil { store.subscribedThreadIDs.contains("thread-0") }

        let reopen = rpc.subscriptionInputs.last
        #expect(reopen?.threadID == "thread-0")
    }

    @Test
    func reopeningCoalescesBehindPendingUnsubscribe() async {
        let threadIDs = (0...6).map { "thread-\($0)" }
        let rpc = MockThreadRPCClient(threads: threadIDs.map { makeThread($0) })
        rpc.shouldBlockUnsubscribe = true
        let store = ThreadStore(rpc: rpc)
        await store.start()

        for threadID in threadIDs {
            store.selectThread(threadID)
            await waitUntil { store.subscribedThreadIDs.contains(threadID) }
        }
        await waitUntil { rpc.unsubscribedThreadIDs == ["thread-0"] }

        let subscriptionCount = rpc.subscriptionCount(for: "thread-0")
        store.selectThread("thread-0")
        store.selectThread("thread-1")
        store.selectThread("thread-0")
        await Task.yield()
        #expect(rpc.subscriptionCount(for: "thread-0") == subscriptionCount)

        rpc.resumeUnsubscribes()
        await waitUntil {
            rpc.subscriptionCount(for: "thread-0") == subscriptionCount + 1
        }
        await waitUntil { store.subscribedThreadIDs.contains("thread-0") }
        await Task.yield()
        #expect(rpc.subscriptionCount(for: "thread-0") == subscriptionCount + 1)
    }

    @Test
    func inactiveSubscribedThreadReceivesBackgroundUpdates() async throws {
        let rpc = MockThreadRPCClient(threads: [makeThread("a"), makeThread("b")])
        let store = ThreadStore(rpc: rpc)
        await store.start()

        store.selectThread("a")
        await waitUntil { store.subscribedThreadIDs.contains("a") }
        store.selectThread("b")
        await waitUntil { store.inactiveSubscribedThreadIDs.contains("a") }

        try rpc.sendTitleUpdate(threadID: "a", title: "Updated in background", sequence: 100)

        #expect(store.cachedThread(for: "a")?.title == "Updated in background")
        #expect(store.inactiveSubscribedThreadIDs.contains("a"))
    }

    @Test
    func retryResubscribesSelectedThreadAfterSnapshotFailure() async {
        let rpc = MockThreadRPCClient(threads: [makeThread("a")])
        rpc.threadSubscriptionFailuresRemaining = 1
        let store = ThreadStore(rpc: rpc)
        await store.start()

        store.selectThread("a")
        await waitUntil {
            rpc.subscriptionCount(for: "a") == 1
                && store.selectedThreadLoadErrorMessage != nil
        }

        store.retry()
        await waitUntil { rpc.subscriptionCount(for: "a") == 2 }
        await waitUntil { store.subscribedThreadIDs.contains("a") }

        #expect(store.selectedThreadLoadErrorMessage == nil)
        #expect(store.selectedThread?.id == "a")
    }

    @Test
    func threadListOwnsAuthoritativeUpdatedAt() async throws {
        let initialDate = Date(timeIntervalSince1970: 1_000)
        let replayDate = Date(timeIntervalSince1970: 2_000)
        let thread = makeThread("a").with(updatedAt: initialDate)
        let rpc = MockThreadRPCClient(threads: [thread])
        let store = ThreadStore(rpc: rpc)
        await store.start()
        store.selectThread("a")
        await waitUntil { store.subscribedThreadIDs.contains("a") }

        try rpc.sendUserMessage(
            threadID: "a",
            text: "restored prompt",
            occurredAt: replayDate,
            authoritativeUpdatedAt: initialDate,
            sequence: 100
        )

        #expect(store.threads.first(where: { $0.id == "a" })?.updatedAt == initialDate)
        #expect(store.cachedThread(for: "a")?.timeline.last?.message?.text == "restored prompt")
        #expect(store.cachedThread(for: "a")?.updatedAt == initialDate)
    }

    @Test
    func subscribeRecoveryAppliesBufferedDetailAndListUpdates() async throws {
        let initialDate = Date(timeIntervalSince1970: 1_000)
        let updatedDate = Date(timeIntervalSince1970: 2_000)
        let thread = makeThread("a").with(updatedAt: initialDate)
        let rpc = MockThreadRPCClient(threads: [thread])
        rpc.shouldBlockSubscribe = true
        let store = ThreadStore(rpc: rpc)
        await store.start()

        store.selectThread("a")
        await waitUntil { rpc.subscriptionCount(for: "a") == 1 }
        try rpc.sendUserMessage(
            threadID: "a",
            text: "message during recovery",
            occurredAt: updatedDate,
            authoritativeUpdatedAt: updatedDate,
            sequence: 100
        )

        rpc.resumeSubscribes()
        await waitUntil { store.subscribedThreadIDs.contains("a") }

        #expect(
            store.cachedThread(for: "a")?.timeline.last?.message?.text
                == "message during recovery"
        )
        #expect(store.threads.first(where: { $0.id == "a" })?.updatedAt == updatedDate)
        #expect(store.cachedThread(for: "a")?.updatedAt == initialDate)
    }

    @Test
    func detailSnapshotDoesNotOverrideThreadListUpdatedAt() async throws {
        let staleDate = Date(timeIntervalSince1970: 1_000)
        let currentDate = Date(timeIntervalSince1970: 2_000)
        let listThread = makeThread("a").with(updatedAt: staleDate)
        let detailThread = listThread.with(updatedAt: currentDate)
        let rpc = MockThreadRPCClient(
            threads: [listThread],
            detailThreads: [detailThread],
            detailSnapshotSequence: 101
        )
        let store = ThreadStore(rpc: rpc)
        await store.start()
        store.selectThread("a")
        await waitUntil { store.subscribedThreadIDs.contains("a") }

        #expect(store.cachedThread(for: "a")?.updatedAt == currentDate)
        #expect(store.threads.first(where: { $0.id == "a" })?.updatedAt == staleDate)

        try rpc.sendThreadListTimestamp(
            threadID: "a",
            updatedAt: currentDate,
            sequence: 100
        )
        #expect(store.cachedThread(for: "a")?.updatedAt == currentDate)
        #expect(store.threads.first(where: { $0.id == "a" })?.updatedAt == currentDate)
    }

    @Test
    func protectedThreadGetsFullInactiveTTLAfterCompletion() async throws {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let rpc = MockThreadRPCClient(threads: [
            makeThread("running", isRunning: true),
            makeThread("other"),
        ])
        let store = ThreadStore(rpc: rpc, now: { currentDate })
        await store.start()

        store.selectThread("running")
        await waitUntil { store.subscribedThreadIDs.contains("running") }
        store.selectThread("other")
        await waitUntil { store.protectedSubscribedThreadIDs.contains("running") }

        currentDate = currentDate.addingTimeInterval(31 * 60)
        try rpc.sendTurnInterrupted(
            threadID: "running",
            turnID: "turn-running",
            occurredAt: currentDate,
            sequence: 100
        )

        #expect(store.inactiveSubscribedThreadIDs.contains("running"))
        store.performSubscriptionMaintenance(
            at: currentDate.addingTimeInterval(30 * 60 - 1)
        )
        #expect(store.subscribedThreadIDs.contains("running"))

        store.performSubscriptionMaintenance(
            at: currentDate.addingTimeInterval(30 * 60 + 1)
        )
        await Task.yield()
        #expect(!store.subscribedThreadIDs.contains("running"))
    }

    @Test
    func reconnectKeepsCachedContentAndRequestsFreshSnapshots() async {
        let rpc = MockThreadRPCClient(threads: [makeThread("a")])
        let store = ThreadStore(rpc: rpc)
        await store.start()
        store.selectThread("a")
        await waitUntil { store.subscribedThreadIDs.contains("a") }
        let firstSubscriptionCount = rpc.subscriptionInputs.count

        rpc.simulateDisconnect()
        #expect(store.cachedThread(for: "a")?.id == "a")
        #expect(store.subscribedThreadIDs.isEmpty)

        store.retry()
        await waitUntil { rpc.subscriptionInputs.count == firstSubscriptionCount + 1 }
        await waitUntil { store.subscribedThreadIDs.contains("a") }

        let reconnect = rpc.subscriptionInputs.last
        #expect(reconnect?.threadID == "a")
    }

    @Test
    func repeatedReconnectFailurePreservesWarmSubscriptions() async {
        let rpc = MockThreadRPCClient(threads: [makeThread("a"), makeThread("b")])
        let store = ThreadStore(rpc: rpc)
        await store.start()
        store.selectThread("a")
        await waitUntil { store.subscribedThreadIDs.contains("a") }
        store.selectThread("b")
        await waitUntil { store.subscribedThreadIDs.contains("b") }

        rpc.simulateDisconnect()
        rpc.threadListFailuresRemaining = 1
        store.retry()
        await waitUntil {
            rpc.threadListFailuresRemaining == 0 && store.connectionState == .disconnected
        }

        let subscriptionCount = rpc.subscriptionInputs.count
        store.retry()
        await waitUntil { rpc.subscriptionInputs.count == subscriptionCount + 2 }
        await waitUntil { store.subscribedThreadIDs == ["a", "b"] }
    }

    @Test
    func conversationCacheRetainsAllOpenedModelsForAppSession() async {
        let threadIDs = (0..<31).map { "thread-\($0)" }
        let rpc = MockThreadRPCClient(threads: threadIDs.map { makeThread($0) })
        let store = ThreadStore(rpc: rpc)
        await store.start()

        for threadID in threadIDs {
            store.selectThread(threadID)
            await waitUntil { store.subscribedThreadIDs.contains(threadID) }
        }

        #expect(store.cachedThreadIDs == Set(threadIDs))
        #expect(store.subscribedThreadIDs.count == 6)
    }

    @Test
    func draftStorePersistsTheActiveDraft() throws {
        let suiteName = "ThreadDraftStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ThreadDraftStore(defaults: defaults)
        store.setActiveDraftThreadID("thread-a")
        store.setText("First prompt", for: "thread-a")
        store.preferences.rememberProvider("codex")
        store.preferences.rememberWorkingDirectory("/tmp/project")
        store.preferences.rememberConfigValue(
            JSONAny("high"),
            providerID: "codex",
            optionID: "reasoning"
        )

        let restored = ThreadDraftStore(defaults: defaults)
        #expect(restored.activeDraftThreadID == "thread-a")
        #expect(restored.text(for: "thread-a") == "First prompt")
        #expect(restored.preferences.providerID == "codex")
        #expect(restored.preferences.workingDirectory == "/tmp/project")
        #expect(
            restored.preferences.configValue(
                providerID: "codex",
                optionID: "reasoning"
            )?.value as? String == "high"
        )

        restored.setText("  \n", for: "thread-a")
        #expect(ThreadDraftStore(defaults: defaults).text(for: "thread-a").isEmpty)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        attempts: Int = 100
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condition was not satisfied before timeout")
    }
}

@MainActor
private final class MockThreadRPCClient: ThreadRPCClient {
    var onNotification: ((String, Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    private(set) var subscriptionInputs: [SubscribeThreadInput] = []
    private(set) var unsubscribedThreadIDs: [String] = []
    var shouldBlockSubscribe = false
    var shouldBlockUnsubscribe = false
    var threadListFailuresRemaining = 0
    var threadSubscriptionFailuresRemaining = 0

    private var subscribeContinuations:
        [(continuation: CheckedContinuation<ThreadStreamItem, Never>, snapshot: ThreadStreamItem)] = []
    private var unsubscribeContinuations: [CheckedContinuation<Void, Never>] = []
    private let threadListItem: ThreadListStreamItem
    private let snapshotsByID: [String: ThreadStreamItem]

    init(
        threads: [mai.Thread],
        detailThreads: [mai.Thread]? = nil,
        detailSnapshotSequence: Int? = nil
    ) {
        let entries = threads.map(makeThreadListEntry)
        threadListItem = ThreadListStreamItem(
            kind: "snapshot",
            sequence: nil,
            snapshot: ThreadListSnapshot(
                snapshotSequence: 0,
                threads: entries,
                updatedAt: .now
            ),
            thread: nil
        )
        let detailThreads = detailThreads ?? threads
        snapshotsByID = Dictionary(
            uniqueKeysWithValues: detailThreads.enumerated().map { index, thread in
                (
                    thread.id,
                    ThreadStreamItem(
                        event: nil,
                        kind: "snapshot",
                        snapshot: ThreadDetailSnapshot(
                            snapshotSequence: detailSnapshotSequence ?? index + 1,
                            thread: thread
                        )
                    )
                )
            }
        )
    }

    func connect() {}

    func disconnect() {}

    func subscribeThreadList() async throws -> ThreadListStreamItem {
        if threadListFailuresRemaining > 0 {
            threadListFailuresRemaining -= 1
            onDisconnect?(MockError.disconnected)
            throw MockError.disconnected
        }
        return threadListItem
    }

    func subscribeThread(_ input: SubscribeThreadInput) async throws -> ThreadStreamItem {
        subscriptionInputs.append(input)
        if threadSubscriptionFailuresRemaining > 0 {
            threadSubscriptionFailuresRemaining -= 1
            throw MockError.subscriptionFailed
        }
        guard let snapshot = snapshotsByID[input.threadID] else {
            throw MockError.missingThread(input.threadID)
        }
        if shouldBlockSubscribe {
            return await withCheckedContinuation { continuation in
                subscribeContinuations.append((continuation, snapshot))
            }
        }
        return snapshot
    }

    func unsubscribeThread(_ input: SubscribeThreadInput) async throws {
        unsubscribedThreadIDs.append(input.threadID)
        if shouldBlockUnsubscribe {
            await withCheckedContinuation { continuation in
                unsubscribeContinuations.append(continuation)
            }
        }
    }

    func resumeUnsubscribes() {
        shouldBlockUnsubscribe = false
        let continuations = unsubscribeContinuations
        unsubscribeContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func resumeSubscribes() {
        shouldBlockSubscribe = false
        let continuations = subscribeContinuations
        subscribeContinuations.removeAll()
        for pending in continuations {
            pending.continuation.resume(returning: pending.snapshot)
        }
    }

    func subscriptionCount(for threadID: String) -> Int {
        subscriptionInputs.filter { $0.threadID == threadID }.count
    }

    func simulateDisconnect() {
        onDisconnect?(MockError.disconnected)
    }

    func sendTitleUpdate(threadID: String, title: String, sequence: Int) throws {
        let event = Event(
            actor: nil,
            commandID: nil,
            eventID: "event-\(sequence)",
            metadata: nil,
            occurredAt: .now,
            payload: makeEventPayload(threadID: threadID, title: title),
            sequence: sequence,
            type: "thread.meta-updated"
        )
        let item = ThreadStreamItem(event: event, kind: "event", snapshot: nil)
        let data = try newJSONEncoder().encode(MockNotification(params: item))
        onNotification?(MaidRPCMethod.orchestrationSubscribeThread, data)
    }

    func sendUserMessage(
        threadID: String,
        text: String,
        occurredAt: Date,
        authoritativeUpdatedAt: Date,
        sequence: Int
    ) throws {
        guard snapshotsByID[threadID]?.snapshot?.thread != nil else {
            throw MockError.missingThread(threadID)
        }
        let event = Event(
            actor: nil,
            commandID: nil,
            eventID: "event-\(sequence)",
            metadata: nil,
            occurredAt: occurredAt,
            payload: makeEventPayload(
                threadID: threadID,
                messageID: "message-\(sequence)",
                role: "user",
                text: text
            ),
            sequence: sequence,
            type: "thread.message-sent"
        )
        let threadItem = ThreadStreamItem(event: event, kind: "event", snapshot: nil)
        let threadData = try newJSONEncoder().encode(MockNotification(params: threadItem))
        onNotification?(MaidRPCMethod.orchestrationSubscribeThread, threadData)

        try sendThreadListTimestamp(
            threadID: threadID,
            updatedAt: authoritativeUpdatedAt,
            sequence: sequence
        )
    }

    func sendThreadListTimestamp(
        threadID: String,
        updatedAt: Date,
        sequence: Int
    ) throws {
        guard let thread = snapshotsByID[threadID]?.snapshot?.thread else {
            throw MockError.missingThread(threadID)
        }
        let item = ThreadListStreamItem(
            kind: "thread-upserted",
            sequence: sequence,
            snapshot: nil,
            thread: makeThreadListEntry(thread).with(updatedAt: updatedAt)
        )
        let data = try newJSONEncoder().encode(MockNotification(params: item))
        onNotification?(MaidRPCMethod.orchestrationSubscribeThreadList, data)
    }

    func sendTurnInterrupted(
        threadID: String,
        turnID: String,
        occurredAt: Date,
        sequence: Int
    ) throws {
        let event = Event(
            actor: nil,
            commandID: nil,
            eventID: "event-\(sequence)",
            metadata: nil,
            occurredAt: occurredAt,
            payload: makeEventPayload(threadID: threadID, turnID: turnID),
            sequence: sequence,
            type: "thread.turn-interrupt-confirmed"
        )
        let item = ThreadStreamItem(event: event, kind: "event", snapshot: nil)
        let data = try newJSONEncoder().encode(MockNotification(params: item))
        onNotification?(MaidRPCMethod.orchestrationSubscribeThread, data)
    }

    private enum MockError: Error {
        case disconnected
        case missingThread(String)
        case subscriptionFailed
    }

    private struct MockNotification<Params: Encodable>: Encodable {
        let params: Params
    }
}

@MainActor
private func makeThreadListEntry(_ thread: mai.Thread) -> ThreadListEntry {
    ThreadListEntry(
        createdAt: thread.createdAt,
        cwd: thread.cwd,
        draft: thread.draft,
        hasPendingApprovals: thread.timeline.contains { $0.approval?.status == "pending" },
        id: thread.id,
        latestTurn: thread.latestTurn,
        modelSelection: thread.modelSelection,
        providerInstanceID: thread.providerInstanceID,
        session: thread.session,
        title: thread.title,
        updatedAt: thread.updatedAt
    )
}

@MainActor
private func makeEventPayload(
    threadID: String,
    messageID: String? = nil,
    role: String? = nil,
    text: String? = nil,
    title: String? = nil,
    turnID: String? = nil
) -> EventPayload {
    EventPayload(
        approval: nil,
        attachments: nil,
        configOptions: nil,
        createdAt: nil,
        cwd: nil,
        decision: nil,
        item: nil,
        messageID: messageID,
        modelSelection: nil,
        optionID: nil,
        plan: nil,
        providerInstanceID: nil,
        requestID: nil,
        role: role,
        session: nil,
        sessionCleared: nil,
        slashCommands: nil,
        stopReason: nil,
        text: text,
        threadID: threadID,
        title: title,
        tokenUsage: nil,
        turnID: turnID,
        updatedAt: nil,
        value: nil
    )
}

@MainActor
private func makeThread(_ id: String, isRunning: Bool = false) -> mai.Thread {
    let turn = isRunning
        ? Turn(
            completedAt: nil,
            error: nil,
            interruptRequested: false,
            requestedAt: .now,
            startedAt: .now,
            state: "running",
            stopReason: nil,
            turnID: "turn-\(id)"
        )
        : nil
    return mai.Thread(
        createdAt: .now,
        cwd: nil,
        draft: false,
        id: id,
        latestTurn: turn,
        modelSelection: nil,
        plan: nil,
        providerInstanceID: "provider",
        session: nil,
        timeline: [],
        title: id,
        updatedAt: .now
    )
}
