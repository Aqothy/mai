import Foundation
import Observation
import Synchronization
import Testing
@testable import mai

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
    func hiddenThreadEventsDoNotInvalidateSelectedThreadObservers() async throws {
        let rpc = MockThreadRPCClient(threads: [makeThread("a"), makeThread("b")])
        let store = ThreadStore(rpc: rpc)
        await store.start()

        store.selectThread("a")
        await waitUntil { store.subscribedThreadIDs.contains("a") }
        store.selectThread("b")
        await waitUntil { store.subscribedThreadIDs.contains("b") }
        await waitUntil { store.inactiveSubscribedThreadIDs.contains("a") }

        let selectedObserverInvalidated = Mutex(false)
        withObservationTracking {
            _ = store.selectedThread
        } onChange: {
            selectedObserverInvalidated.withLock { $0 = true }
        }

        try rpc.sendTitleUpdate(threadID: "a", title: "Hidden update", sequence: 100)
        #expect(store.cachedThread(for: "a")?.title == "Hidden update")
        #expect(!selectedObserverInvalidated.withLock { $0 })

        try rpc.sendTitleUpdate(threadID: "b", title: "Visible update", sequence: 101)
        await waitUntil { selectedObserverInvalidated.withLock { $0 } }
        #expect(store.selectedThread?.title == "Visible update")
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
    func threadListTimestampRemainsAuthoritativeAcrossDetailUpdates() async throws {
        let listDate = Date(timeIntervalSince1970: 1_000)
        let detailDate = Date(timeIntervalSince1970: 2_000)
        let finalListDate = Date(timeIntervalSince1970: 3_000)
        let listThread = makeThread("a").with(updatedAt: listDate)
        let detailThread = listThread.with(updatedAt: detailDate)
        let rpc = MockThreadRPCClient(
            threads: [listThread],
            detailThreads: [detailThread],
            detailSnapshotSequence: 101
        )
        let store = ThreadStore(rpc: rpc)
        await store.start()
        store.selectThread("a")
        await waitUntil { store.subscribedThreadIDs.contains("a") }

        #expect(store.cachedThread(for: "a")?.updatedAt == detailDate)
        #expect(store.threads.first(where: { $0.id == "a" })?.updatedAt == listDate)

        try rpc.sendUserMessage(
            threadID: "a",
            text: "restored prompt",
            occurredAt: finalListDate,
            authoritativeUpdatedAt: listDate,
            sequence: 102
        )
        #expect(store.cachedThread(for: "a")?.timeline.last?.message?.text == "restored prompt")
        #expect(store.threads.first(where: { $0.id == "a" })?.updatedAt == listDate)

        try rpc.sendThreadListTimestamp(
            threadID: "a",
            updatedAt: finalListDate,
            sequence: 103
        )
        #expect(store.threads.first(where: { $0.id == "a" })?.updatedAt == finalListDate)
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
    func restoredThreadPreparationIsLimitedAndRetryable() async {
        let rpc = MockThreadRPCClient(threads: [
            makeThread("restored"),
            makeThread("active", isRunning: true),
        ])
        rpc.prepareFailuresRemaining = 1
        let store = ThreadStore(rpc: rpc)
        await store.start()

        store.selectThread("restored")
        await waitUntil {
            rpc.prepareFailuresRemaining == 0
                && store.selectedThreadLoadErrorMessage != nil
        }

        store.retry()
        await waitUntil {
            rpc.dispatchedCommands.filter {
                $0.type == "thread.session.prepare" && $0.threadID == "restored"
            }.count == 2
        }

        #expect(store.selectedThreadLoadErrorMessage == nil)

        store.selectThread("active")
        await waitUntil { store.selectedThread?.id == "active" }
        await Task.yield()

        #expect(
            !rpc.dispatchedCommands.contains {
                $0.type == "thread.session.prepare" && $0.threadID == "active"
            }
        )
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
        #expect(ThreadDraftStore(defaults: defaults).text(for: "thread-a") == "  \n")
    }

    @Test
    func localDraftLoadsProviderOptionsWithoutCreatingAThread() async throws {
        let suiteName = "DraftOptionsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rpc = MockThreadRPCClient(threads: [])
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let draftStore = ThreadDraftStore(defaults: defaults)
        let model = DraftPromptModel(store: store, draftStore: draftStore)
        model.ensureLocalDraft()
        model.selectedProviderID = "codex"
        model.workingDirectory = "/tmp/project"

        await model.loadOptions()

        #expect(model.optionsPhase == .live)
        #expect(model.configOptions.map(\.id) == ["model"])
        #expect(rpc.dispatchedCommands.isEmpty)

        model.workingDirectory = "/tmp/other"

        #expect(model.configOptions.isEmpty)
        #expect(draftStore.preferences.providerID == "codex")
        #expect(draftStore.preferences.workingDirectory == "/tmp/other")
    }

    @Test
    func configUpdatesAreSentInSelectionOrder() async throws {
        let suiteName = "DraftConfigOrderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rpc = MockThreadRPCClient(threads: [])
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let model = DraftPromptModel(
            store: store,
            draftStore: ThreadDraftStore(defaults: defaults)
        )
        model.ensureLocalDraft()
        model.selectedProviderID = "codex"
        model.workingDirectory = "/tmp/project"
        await model.loadOptions()

        rpc.shouldBlockProviderOptionSet = true
        model.updateConfig("model", value: JSONAny("slow"))
        await waitUntil { rpc.providerOptionSetInputs.count == 1 }
        model.updateConfig("model", value: JSONAny("fast"))

        #expect(rpc.providerOptionSetInputs.count == 1)
        rpc.resumeProviderOptionSets()
        await waitUntil { rpc.providerOptionSetInputs.count == 2 }
        await waitUntil {
            model.configOptions.first?.currentValue?.value as? String == "fast"
        }

        #expect(
            rpc.providerOptionSetInputs.compactMap { $0.value.value as? String }
                == ["slow", "fast"]
        )
    }

    @Test
    func sendSnapshotsDraftBeforeProviderStartup() async throws {
        let suiteName = "DraftSendSnapshotTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rpc = MockThreadRPCClient(threads: [])
        rpc.providerStatus = "stopped"
        rpc.shouldBlockProviderStart = true
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let draftStore = ThreadDraftStore(defaults: defaults)
        let model = DraftPromptModel(store: store, draftStore: draftStore)
        model.ensureLocalDraft()
        let threadID = try #require(draftStore.activeDraftThreadID)
        model.selectedProviderID = "codex"
        model.workingDirectory = "/tmp/original"
        model.prompt = "Original prompt"

        let sendTask = Task {
            await model.send()
        }
        await waitUntil { rpc.providerStartInputs == ["codex"] }
        #expect(model.isSending)

        model.workingDirectory = "/tmp/changed"
        model.prompt = "Changed prompt"
        rpc.resumeProviderStarts()
        await sendTask.value

        let input = try #require(rpc.dispatchedCommands.first { $0.type == "thread.start" })
        #expect(input.cwd == "/tmp/original")
        #expect(input.message?.text == "Original prompt")
        #expect(store.selectedThreadID == threadID)
        #expect(draftStore.activeDraftThreadID == nil)
        #expect(draftStore.text(for: threadID).isEmpty)
    }

    @Test
    func authoritativeThreadListReconcilesAcceptedDraftAfterEdits() async throws {
        let suiteName = "DraftReconnectReconciliationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rpc = MockThreadRPCClient(threads: [])
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let draftStore = ThreadDraftStore(defaults: defaults)
        draftStore.setActiveDraftThreadID("accepted-thread")
        draftStore.setText("Edited while offline", for: "accepted-thread")
        let model = DraftPromptModel(store: store, draftStore: draftStore)
        model.selectedProviderID = "codex"
        model.workingDirectory = "/tmp/project"

        try rpc.sendThreadUpsert(
            makeThread("accepted-thread", isRunning: true),
            sequence: 1
        )
        await model.loadOptions()

        #expect(store.selectedThreadID == "accepted-thread")
        #expect(draftStore.activeDraftThreadID == nil)
        #expect(draftStore.text(for: "accepted-thread").isEmpty)
    }

    private func waitUntil(
        _ condition: () -> Bool,
        attempts: Int = 100
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condition was not satisfied before timeout")
    }
}

private final class MockThreadRPCClient: ThreadRPCClient {
    var onNotification: ((String, Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    private(set) var subscriptionInputs: [SubscribeThreadInput] = []
    private(set) var unsubscribedThreadIDs: [String] = []
    private(set) var dispatchedCommands: [Command] = []
    private(set) var providerStartInputs: [String] = []
    private(set) var providerOptionSetInputs: [ProviderOptionsSetParams] = []
    var shouldBlockSubscribe = false
    var shouldBlockUnsubscribe = false
    var shouldBlockProviderStart = false
    var shouldBlockProviderOptionSet = false
    var threadListFailuresRemaining = 0
    var threadSubscriptionFailuresRemaining = 0
    var prepareFailuresRemaining = 0
    var providerStatus = "initialized"
    var providerOptions = [
        ConfigOption(
            category: "model",
            choices: [ConfigChoice(label: "Fast", value: "fast")],
            currentValue: JSONAny("fast"),
            description: nil,
            id: "model",
            label: "Model",
            type: "select"
        )
    ]

    private var subscribeContinuations:
        [(continuation: CheckedContinuation<ThreadStreamItem, Never>, snapshot: ThreadStreamItem)] = []
    private var unsubscribeContinuations: [CheckedContinuation<Void, Never>] = []
    private var providerStartContinuations: [CheckedContinuation<Void, Never>] = []
    private var providerOptionSetContinuations: [CheckedContinuation<Void, Never>] = []
    private let threadListItem: ThreadListStreamItem
    private var snapshotsByID: [String: ThreadStreamItem]

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

    func listProviders() async throws -> [InstanceInfo] {
        [makeProvider(status: providerStatus)]
    }

    func startProvider(_ instanceID: String) async throws -> InstanceInfo {
        providerStartInputs.append(instanceID)
        if shouldBlockProviderStart {
            await withCheckedContinuation { continuation in
                providerStartContinuations.append(continuation)
            }
        }
        providerStatus = "initialized"
        return makeProvider(status: providerStatus)
    }

    func getProviderOptions(_ input: ProviderOptionsGetParams) async throws -> ProviderOptionsResult {
        ProviderOptionsResult(
            configOptions: providerOptions,
            optionsSessionID: "options-session-1"
        )
    }

    func setProviderOption(_ input: ProviderOptionsSetParams) async throws -> ProviderOptionsResult {
        providerOptionSetInputs.append(input)
        if shouldBlockProviderOptionSet {
            await withCheckedContinuation { continuation in
                providerOptionSetContinuations.append(continuation)
            }
        }
        providerOptions = providerOptions.map { option in
            option.id == input.optionID ? option.with(currentValue: input.value) : option
        }
        return ProviderOptionsResult(
            configOptions: providerOptions,
            optionsSessionID: input.optionsSessionID
        )
    }

    func resumeProviderStarts() {
        shouldBlockProviderStart = false
        let continuations = providerStartContinuations
        providerStartContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func resumeProviderOptionSets() {
        shouldBlockProviderOptionSet = false
        let continuations = providerOptionSetContinuations
        providerOptionSetContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func dispatchCommand(_ command: Command) async throws -> DispatchResult {
        dispatchedCommands.append(command)
        if command.type == "thread.session.prepare", prepareFailuresRemaining > 0 {
            prepareFailuresRemaining -= 1
            throw MockError.prepareFailed
        }
        if command.type == "thread.start", let threadID = command.threadID {
            let thread = makeThread(threadID).with(
                cwd: .some(command.cwd),
                providerInstanceID: .some(command.providerInstanceID),
                title: command.title ?? command.message?.text ?? "Untitled thread"
            )
            snapshotsByID[threadID] = ThreadStreamItem(
                event: nil,
                kind: "snapshot",
                snapshot: ThreadDetailSnapshot(snapshotSequence: 1, thread: thread)
            )
        } else if command.type == "thread.create", let threadID = command.threadID {
            let session = SessionBinding(
                activeTurnID: nil,
                configOptions: nil,
                cwd: command.cwd,
                lastError: nil,
                provider: nil,
                providerInstanceID: command.providerInstanceID ?? "codex",
                providerName: nil,
                slashCommands: nil,
                status: "starting",
                stopRequested: false,
                threadID: threadID,
                tokenUsage: nil,
                updatedAt: .now
            )
            let thread = makeThread(threadID).with(
                cwd: .some(command.cwd),
                modelSelection: .some(command.modelSelection),
                providerInstanceID: .some(command.providerInstanceID),
                session: .some(session)
            )
            snapshotsByID[threadID] = ThreadStreamItem(
                event: nil,
                kind: "snapshot",
                snapshot: ThreadDetailSnapshot(
                    snapshotSequence: 1,
                    thread: thread
                )
            )
        } else if command.type == "thread.session.prepare", let threadID = command.threadID,
                  let starting = snapshotsByID[threadID]?.snapshot?.thread.session {
            let session = starting.with(status: "ready", updatedAt: .now)
            let event = Event(
                actor: nil,
                commandID: command.commandID,
                eventID: "session-ready-\(threadID)",
                metadata: nil,
                occurredAt: .now,
                payload: makeEventPayload(threadID: threadID, session: session),
                sequence: 2,
                type: "thread.session-status-set"
            )
            let item = ThreadStreamItem(event: event, kind: "event", snapshot: nil)
            let data = try newJSONEncoder().encode(MockNotification(params: item))
            Task { [weak self] in
                await Task.yield()
                self?.onNotification?(MaidRPCMethod.orchestrationSubscribeThread, data)
            }
        }
        return DispatchResult(sequence: 1)
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

    private func makeProvider(status: String) -> InstanceInfo {
        InstanceInfo(
            auth: Auth(methods: nil, status: "authenticated"),
            capabilities: Capabilities(
                auth: nil,
                configOptions: true,
                loadReplay: nil,
                logout: nil,
                mcp: nil,
                modelSwitch: nil,
                promptContent: nil,
                resume: nil
            ),
            driver: "mock",
            initializedAt: .now,
            instanceID: "codex",
            name: "Codex",
            pid: nil,
            startedAt: .now,
            status: status
        )
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

    func sendThreadUpsert(_ thread: mai.Thread, sequence: Int) throws {
        snapshotsByID[thread.id] = ThreadStreamItem(
            event: nil,
            kind: "snapshot",
            snapshot: ThreadDetailSnapshot(snapshotSequence: sequence, thread: thread)
        )
        let item = ThreadListStreamItem(
            kind: "thread-upserted",
            sequence: sequence,
            snapshot: nil,
            thread: makeThreadListEntry(thread)
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
        case prepareFailed
        case subscriptionFailed
    }

    private struct MockNotification<Params: Encodable>: Encodable {
        let params: Params
    }
}

private func makeThreadListEntry(_ thread: mai.Thread) -> ThreadListEntry {
    ThreadListEntry(
        createdAt: thread.createdAt,
        cwd: thread.cwd,
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

private func makeEventPayload(
    threadID: String,
    messageID: String? = nil,
    role: String? = nil,
    text: String? = nil,
    title: String? = nil,
    turnID: String? = nil,
    session: SessionBinding? = nil
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
        session: session,
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
