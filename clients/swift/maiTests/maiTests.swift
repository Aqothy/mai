import Foundation
import Observation
import Synchronization
import Testing
@testable import mai

struct ThreadStoreTests {
    /// Notifications decode with the wire date strategy (fractional seconds
    /// and offsets), not Foundation's default.
    @Test
    func fractionalDateNotificationsUpdateTheSidebar() async throws {
        let original = makeSummary("date-wire")
        let rpc = MockThreadRPCClient(threads: [original])
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let summaryData = try newJSONEncoder().encode(original)
        var summary = try #require(JSONSerialization.jsonObject(with: summaryData) as? [String: Any])
        summary["title"] = "Fractional sidebar"
        summary["updatedAt"] = "2026-09-24T00:26:41.437657-04:00"
        let update: [String: Any] = ["params": [
            "kind": MaidThreadListKind.upsert.rawValue, "seq": 101, "thread": summary
        ]]
        rpc.onNotification?(MaidRPCMethod.threadList, try JSONSerialization.data(withJSONObject: update))
        #expect(store.errorMessage == nil)
        let listed = try #require(store.threads.first)
        #expect(listed.title == "Fractional sidebar")
        #expect(abs(listed.updatedAt.timeIntervalSince1970 - 1_790_224_001.437657) < 0.000001)
    }

    @Test
    func fileCompletionKeepsNewestResultsWhenSearchesFinishOutOfOrder() async throws {
        let rpc = MockThreadRPCClient(threads: [])
        defer { rpc.cancelFileSearches() }
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let model = PromptCompletionModel(store: store, scope: .workingDirectory("/qa"))
        model.update(text: "@old", cursorOffset: 4)
        let old = Task { await model.search() }
        await waitUntil { rpc.fileSearchInputs.count == 1 }
        model.update(text: "@new", cursorOffset: 4)
        let newest = Task { await model.search() }
        await waitUntil { rpc.fileSearchInputs.count == 2 }
        #expect(rpc.fileSearchInputs.map(\.query) == ["old", "new"])
        #expect(rpc.fileSearchInputs.allSatisfy { $0.cwd == "/qa" && $0.threadID == nil && $0.limit == 50 })
        rpc.completeFileSearch(1, result: .success(WorkspaceSearchFilesResult(entries: [WorkspaceFileEntry(displayName: "New", relativePath: "new.swift")], indexing: false)))
        await newest.value
        #expect(model.matches.map(\.insertionValue) == ["new.swift"])
        rpc.completeFileSearch(0, result: .success(WorkspaceSearchFilesResult(entries: [WorkspaceFileEntry(displayName: "Old", relativePath: "old.swift")], indexing: false)))
        await old.value
        #expect(model.phase == .results)
        #expect(model.matches.map(\.insertionValue) == ["new.swift"])
        #expect(model.editBySelectingCurrentMatch(in: "@new")?.text == "@new.swift ")
    }

    @Test
    func fileCompletionDiscardsRepliesAfterScopeChangeDismissalAndCancellation() async throws {
        let rpc = MockThreadRPCClient(threads: [])
        defer { rpc.cancelFileSearches() }
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let model = PromptCompletionModel(store: store, scope: .thread(id: "a"))
        model.update(text: "@", cursorOffset: 1)
        let first = Task { await model.search() }
        await waitUntil { rpc.fileSearchInputs.count == 1 }
        let firstKey = model.searchKey
        model.updateScope(.thread(id: "b"))
        #expect(!model.isPresented)
        let text = model.textByPresentingFileCompletion(in: "")
        #expect(text == "@")
        #expect(model.searchKey != firstKey)
        let second = Task { await model.search() }
        await waitUntil { rpc.fileSearchInputs.count == 2 }
        #expect(rpc.fileSearchInputs.map(\.threadID) == ["a", "b"])
        rpc.completeFileSearch(0, result: .failure(URLError(.timedOut)))
        await first.value
        #expect(model.phase == .loading)
        #expect(model.dismiss())
        rpc.completeFileSearch(1, result: .success(WorkspaceSearchFilesResult(entries: [WorkspaceFileEntry(displayName: "Stale", relativePath: "stale")], indexing: false)))
        await second.value
        #expect(!model.isPresented)
        #expect(model.matches.isEmpty)
        model.update(text: "@", cursorOffset: 1)
        #expect(!model.isPresented)
        _ = model.textByPresentingFileCompletion(in: "")
        let cancelled = Task { await model.search() }
        await waitUntil { rpc.fileSearchInputs.count == 3 }
        cancelled.cancel()
        rpc.completeFileSearch(2, result: .success(WorkspaceSearchFilesResult(entries: [WorkspaceFileEntry(displayName: "Cancelled", relativePath: "cancelled")], indexing: false)))
        await cancelled.value
        #expect(model.matches.isEmpty)
        model.update(text: "@", cursorOffset: nil)
        #expect(!model.isPresented)
    }

    @Test
    func fileCompletionRetriesIndexingAndFailureWithoutSplittingUnicodeQuery() async throws {
        let rpc = MockThreadRPCClient(threads: [])
        defer { rpc.cancelFileSearches() }
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let model = PromptCompletionModel(store: store, scope: .workingDirectory("/qa"))
        let query = String(repeating: "👩🏽‍💻", count: 30)
        model.update(text: "@" + query, cursorOffset: query.count + 1)
        #expect(model.query.utf8.count <= 256)
        #expect((model.query + "👩🏽‍💻").utf8.count > 256)
        #expect(model.query.allSatisfy { $0 == "👩🏽‍💻" })
        for index in 0..<3 {
            let key = model.searchKey
            let search = Task { await model.search() }
            await waitUntil { rpc.fileSearchInputs.count == index + 1 }
            #expect(rpc.fileSearchInputs.last?.query == model.query)
            switch index {
            case 0:
                rpc.completeFileSearch(index, result: .success(WorkspaceSearchFilesResult(entries: [], indexing: true)))
            case 1:
                rpc.completeFileSearch(index, result: .failure(URLError(.notConnectedToInternet)))
            default:
                rpc.completeFileSearch(index, result: .success(WorkspaceSearchFilesResult(entries: [WorkspaceFileEntry(displayName: "文件.swift", relativePath: "Sources/文件.swift")], indexing: false)))
            }
            await search.value
            #expect(model.phase == [PromptCompletionModel.Phase.indexing, .failed, .results][index])
            if index < 2 {
                #expect(model.matches.isEmpty)
                model.retry()
                #expect(model.searchKey != key)
            }
        }
        #expect(model.editBySelectingCurrentMatch(in: "@" + query)?.text == "@Sources/文件.swift ")
    }

    @Test
    func reasoningDeltasInvalidateOnlyLiveTextAndCompletionPublishesAuthoritativeText() async throws {
        let rpc = MockThreadRPCClient(threads: [makeSummary("a", status: .running)])
        let store = ThreadStore(rpc: rpc)
        await store.start()
        store.selectThread("a")
        await waitUntil { store.subscribedThreadIDs.contains("a") }
        try rpc.sendEntry(threadID: "a", ref: "thought", kind: .reasoning, status: .inProgress, seq: 100)
        try rpc.sendText(threadID: "a", ref: "thought", text: "Start", seq: 101)
        let liveText = try #require(store.streamingText(threadID: "a", rowID: "turn-a|thought"))
        let invalidated = trackInvalidations(of: store, liveText: liveText)
        for index in 1...20 {
            try rpc.sendText(threadID: "a", ref: "thought", text: " café 👩🏽‍💻", seq: 101 + index)
        }
        #expect(invalidated.text.withLock { $0 })
        #expect(!invalidated.timeline.withLock { $0 })
        #expect(!invalidated.sidebar.withLock { $0 })
        #expect(liveText.text == "Start" + String(repeating: " café 👩🏽‍💻", count: 20))

        // The completed entry can correct streamed text. Publish that change
        // to the disclosure row and discard its live buffer in the same event.
        let authoritative = "Completed **thought** with corrected Unicode 👩🏽‍💻."
        try rpc.sendEntry(threadID: "a", ref: "thought", kind: .reasoning, text: authoritative, seq: 122)
        #expect(invalidated.timeline.withLock { $0 })
        #expect(!invalidated.sidebar.withLock { $0 })
        #expect(store.streamingText(threadID: "a", rowID: "turn-a|thought") == nil)
        let settled = try #require(store.selectedThread?.turns.last?.entries.last)
        #expect(settled.itemStatus == .completed)
        #expect(settled.text == authoritative)
    }

    @Test
    func streamingDeltasInvalidateTheLiveTextWithoutInvalidatingTimelineOrSidebar() async throws {
        let rpc = MockThreadRPCClient(threads: [makeSummary("a", status: .running)])
        let store = ThreadStore(rpc: rpc)
        await store.start()
        store.selectThread("a")
        await waitUntil { store.subscribedThreadIDs.contains("a") }
        try rpc.sendEntry(threadID: "a", ref: "reply", kind: .assistantMessage, status: .inProgress, seq: 100)
        try rpc.sendText(threadID: "a", ref: "reply", text: "Start", seq: 101)
        let liveText = try #require(store.streamingText(threadID: "a", rowID: "turn-a|reply"))
        let invalidated = trackInvalidations(of: store, liveText: liveText)
        for index in 1...20 {
            try rpc.sendText(threadID: "a", ref: "reply", text: " 👋🏽", seq: 101 + index)
        }
        #expect(invalidated.text.withLock { $0 })
        #expect(!invalidated.timeline.withLock { $0 })
        #expect(!invalidated.sidebar.withLock { $0 })
        #expect(liveText.text == "Start" + String(repeating: " 👋🏽", count: 20))
        #expect(store.selectedThread?.turns.last?.entries.last?.text == liveText.text)
        // A new entry is structural and must publish the enclosing timeline.
        try rpc.sendEntry(threadID: "a", ref: "next", kind: .assistantMessage, status: .inProgress, seq: 122)
        #expect(invalidated.timeline.withLock { $0 })
    }

    @Test
    func recentChatRetainsPresentationButEvictionReleasesIt() async throws {
        let threadIDs = (0...6).map { "thread-\($0)" }
        let rpc = MockThreadRPCClient(threads: threadIDs.map { makeSummary($0) })
        let store = ThreadStore(rpc: rpc)
        await store.start()
        store.selectThread("thread-0")
        await waitUntil { store.subscribedThreadIDs.contains("thread-0") }

        weak var originalSegments: ChatMarkdownSegmentCache?
        weak var originalLayouts: ChatTextLayoutStore?
        weak var preparedLayout: ChatTextLayout?
        do {
            let segments = try #require(store.selectedThreadMarkdownSegmentCache)
            let layouts = try #require(store.selectedThreadTextLayoutStore)
            originalSegments = segments
            originalLayouts = layouts
            preparedLayout = layouts.layout(
                id: "reply", content: .source("A retained **rich** reply."), width: 320)
            _ = segments.segments(messageID: "reply", source: "A retained **rich** reply.")
        }
        #expect(originalSegments?.entryCount == 1)
        #expect(preparedLayout != nil)

        store.selectThread("thread-1")
        await waitUntil { store.subscribedThreadIDs.contains("thread-1") }
        store.selectThread("thread-0")
        #expect(store.selectedThreadMarkdownSegmentCache === originalSegments)
        #expect(store.selectedThreadTextLayoutStore === originalLayouts)
        #expect(preparedLayout != nil)

        for threadID in threadIDs.dropFirst() {
            store.selectThread(threadID)
            await waitUntil { store.subscribedThreadIDs.contains(threadID) }
        }
        // Five inactive subscriptions stay warm; the oldest is evicted with
        // its content.
        await waitUntil { rpc.unsubscribedThreadIDs == ["thread-0"] }
        #expect(store.inactiveSubscribedThreadIDs == Set(threadIDs[1...5]))
        #expect(store.subscribedThreadIDs == Set(threadIDs[1...6]))
        #expect(store.cachedThreadIDs == Set(threadIDs[1...6]))
        #expect(originalSegments == nil)
        #expect(originalLayouts == nil)
        #expect(preparedLayout == nil)

        // Reopening loads it rather than showing what went stale.
        let subscriptionCount = rpc.subscriptionCount(for: "thread-0")
        store.selectThread("thread-0")
        #expect(store.selectedThread == nil)
        await waitUntil { rpc.subscriptionCount(for: "thread-0") == subscriptionCount + 1 }
        await waitUntil { store.subscribedThreadIDs.contains("thread-0") }
        #expect(store.selectedThread?.id == "thread-0")
        let freshSegments = try #require(store.selectedThreadMarkdownSegmentCache)
        #expect(freshSegments.entryCount == 0)
    }

    /// A chat is caught up with its agent's session before it shows, and
    /// again when the person returns to it while it is still watched.
    @Test
    func openingAChatSyncsItFirstAndReturningSyncsAgain() async {
        let rpc = MockThreadRPCClient(threads: [makeSummary("a"), makeSummary("b")])
        let store = ThreadStore(rpc: rpc)
        await store.start()
        store.selectThread("a")
        await waitUntil { store.subscribedThreadIDs.contains("a") }
        store.selectThread("b")
        await waitUntil { store.subscribedThreadIDs.contains("b") }
        store.selectThread("a")
        await waitUntil { rpc.openCalls.count == 5 }
        #expect(rpc.openCalls == ["sync a", "subscribe a", "sync b", "subscribe b", "sync a"])
    }

    @Test
    func hiddenRunningThreadIsProtectedOutsideIdleBudget() async {
        let running = makeSummary("running", status: .running)
        let idleThreads = (0...5).map { makeSummary("idle-\($0)") }
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
        let rpc = MockThreadRPCClient(threads: [makeSummary("a"), makeSummary("b")])
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
        await waitUntil { rpc.unsubscribedThreadIDs.contains("a") }

        #expect(!store.subscribedThreadIDs.contains("a"))
        #expect(!store.cachedThreadIDs.contains("a"))
    }

    @Test
    func reopeningCoalescesBehindPendingUnsubscribe() async {
        let threadIDs = (0...6).map { "thread-\($0)" }
        let rpc = MockThreadRPCClient(threads: threadIDs.map { makeSummary($0) })
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
    func hiddenThreadEventsDoNotInvalidateSelectedThreadObservers() async throws {
        let rpc = MockThreadRPCClient(threads: [makeSummary("a"), makeSummary("b")])
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

        try rpc.sendSummary(makeSummary("a", title: "Hidden update"), seq: 100)
        #expect(store.cachedThread(for: "a")?.summary.title == "Hidden update")
        #expect(!selectedObserverInvalidated.withLock { $0 })

        try rpc.sendSummary(makeSummary("b", title: "Visible update"), seq: 101)
        await waitUntil { selectedObserverInvalidated.withLock { $0 } }
        #expect(store.selectedThread?.summary.title == "Visible update")
    }

    @Test
    func retryResubscribesSelectedThreadAfterSnapshotFailure() async {
        let rpc = MockThreadRPCClient(threads: [makeSummary("a")])
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

    /// Events and list updates that arrive while the snapshot is on its way
    /// apply on top of it once it lands.
    @Test
    func subscribeRecoveryAppliesBufferedDetailAndListUpdates() async throws {
        let updatedDate = Date(timeIntervalSince1970: 2_000)
        let rpc = MockThreadRPCClient(threads: [makeSummary("a", updatedAt: Date(timeIntervalSince1970: 1_000))])
        rpc.shouldBlockSubscribe = true
        let store = ThreadStore(rpc: rpc)
        await store.start()

        store.selectThread("a")
        await waitUntil { rpc.subscriptionCount(for: "a") == 1 }
        try rpc.sendEntry(
            threadID: "a", ref: "prompt", kind: .userMessage, text: "message during recovery", seq: 100)
        try rpc.sendListUpsert(makeSummary("a", updatedAt: updatedDate), seq: 100)

        rpc.resumeSubscribes()
        await waitUntil { store.subscribedThreadIDs.contains("a") }

        #expect(store.cachedThread(for: "a")?.turns.last?.entries.last?.text == "message during recovery")
        #expect(store.threads.first(where: { $0.id == "a" })?.updatedAt == updatedDate)
    }

    @Test
    func protectedThreadGetsFullInactiveTTLAfterCompletion() async throws {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let rpc = MockThreadRPCClient(threads: [
            makeSummary("running", status: .running),
            makeSummary("other"),
        ])
        let store = ThreadStore(rpc: rpc, now: { currentDate })
        await store.start()

        store.selectThread("running")
        await waitUntil { store.subscribedThreadIDs.contains("running") }
        store.selectThread("other")
        await waitUntil { store.protectedSubscribedThreadIDs.contains("running") }

        currentDate = currentDate.addingTimeInterval(31 * 60)
        try rpc.sendTurn(threadID: "running", state: .interrupted, seq: 100)
        try rpc.sendSummary(makeSummary("running"), seq: 101)

        #expect(store.inactiveSubscribedThreadIDs.contains("running"))
        store.performSubscriptionMaintenance(
            at: currentDate.addingTimeInterval(30 * 60 - 1)
        )
        #expect(store.subscribedThreadIDs.contains("running"))

        store.performSubscriptionMaintenance(
            at: currentDate.addingTimeInterval(30 * 60 + 1)
        )
        await waitUntil { !store.subscribedThreadIDs.contains("running") }
    }

    @Test
    func reconnectKeepsCachedContentAndResubscribesAfterARepeatedFailure() async {
        let rpc = MockThreadRPCClient(threads: [makeSummary("a"), makeSummary("b")])
        let store = ThreadStore(rpc: rpc)
        await store.start()
        store.selectThread("a")
        await waitUntil { store.subscribedThreadIDs.contains("a") }
        store.selectThread("b")
        await waitUntil { store.subscribedThreadIDs.contains("b") }

        rpc.simulateDisconnect()
        #expect(store.cachedThread(for: "a")?.id == "a")
        #expect(store.subscribedThreadIDs.isEmpty)
        rpc.threadListFailuresRemaining = 1
        store.retry()
        await waitUntil {
            rpc.threadListFailuresRemaining == 0 && store.connectionState == .disconnected
        }

        let subscriptionCount = rpc.subscribedThreadIDs.count
        store.retry()
        await waitUntil { rpc.subscribedThreadIDs.count == subscriptionCount + 2 }
        await waitUntil { store.subscribedThreadIDs == ["a", "b"] }
    }

    @Test
    func draftStorePersistsTheActiveDraft() throws {
        let suiteName = "ThreadDraftStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ThreadDraftStore(defaults: defaults)
        store.setActiveDraftThreadID("thread-a")
        store.setText("First prompt", for: "thread-a")
        store.preferences.rememberSelection(
            providerID: "codex",
            workingDirectory: "/tmp/project"
        )
        store.preferences.rememberConfigValue(
            JSONAny("high"),
            providerID: "codex",
            optionID: "reasoning"
        )
        store.flushPendingSave()

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
        restored.flushPendingSave()
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
        #expect(rpc.commands.isEmpty)

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
        let draftID = try #require(draftStore.activeDraftThreadID)
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

        let create = try #require(rpc.commands.compactMap(\.createThread).first)
        #expect(create.workspace.cwd == "/tmp/original")
        #expect(create.prompt?.text == "Original prompt")
        #expect(store.selectedThreadID == "created-1")
        #expect(draftStore.activeDraftThreadID == nil)
        #expect(draftStore.text(for: draftID).isEmpty)
    }

    /// A Start whose reply was lost may have made the chat; sending again
    /// must not make a second one, so both carry the draft's key.
    @Test
    func retriedStartCarriesTheSameKey() async throws {
        let suiteName = "DraftRetryKeyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rpc = MockThreadRPCClient(threads: [])
        rpc.commandFailuresRemaining = 1
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let draftStore = ThreadDraftStore(defaults: defaults)
        let model = DraftPromptModel(store: store, draftStore: draftStore)
        model.ensureLocalDraft()
        model.selectedProviderID = "codex"
        model.workingDirectory = "/tmp/project"
        model.prompt = "Start once"

        await model.send()
        #expect(model.errorMessage != nil)
        #expect(store.selectedThreadID == nil)
        model.isErrorPresented = false
        await model.send()

        let keys = rpc.commands.filter { $0.createThread != nil }.map(\.key)
        #expect(keys.count == 2)
        #expect(keys[0] != nil && keys[0] == keys[1])
        #expect(store.selectedThreadID == "created-1")
    }

    @Test
    func startedDraftDoesNotOfferItsSentImagesAgain() async throws {
        let suiteName = "DraftSentImagesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let rpc = MockThreadRPCClient(threads: [])
        rpc.supportsImages = true
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let draftStore = ThreadDraftStore(defaults: defaults)
        let model = DraftPromptModel(store: store, draftStore: draftStore)
        model.activate()
        model.ensureLocalDraft()
        model.selectedProviderID = "codex"
        model.workingDirectory = "/tmp/project"
        let image = FileManager.default.temporaryDirectory
            .appending(path: "draft-sent-image-\(UUID().uuidString).png")
        try writeOnePixelPNG(to: image)
        defer { try? FileManager.default.removeItem(at: image) }
        await model.addImages(from: [image])
        await waitUntil { model.attachments.allSatisfy { !$0.isProcessing } }
        #expect(model.attachments.count == 1)
        #expect(model.supportsImageAttachments)
        #expect(model.canSend)

        await model.send()
        let create = try #require(rpc.commands.compactMap(\.createThread).first)
        // The image travels on its own; the command names it.
        #expect(create.prompt?.attachments?.map(\.id) == ["upload-1"])
        #expect(create.prompt?.attachments?.allSatisfy { $0.data == nil } == true)

        // The next new chat starts empty instead of offering the sent image.
        model.ensureLocalDraft()
        #expect(model.attachments.isEmpty)
        #expect(!model.canSend)
    }

    /// Unread is the daemon's, so every device agrees: opening an unread
    /// chat reads it there once, and marking it unread asks the daemon.
    @Test
    func readStateGoesToTheDaemon() async throws {
        var unread = makeSummary("a")
        unread.attention.unread = true
        let rpc = MockThreadRPCClient(threads: [unread, makeSummary("b")])
        let store = ThreadStore(rpc: rpc)
        await store.start()
        #expect(store.isThreadUnread("a") && !store.isThreadUnread("b"))

        store.selectThread("a")
        store.selectThread("b")
        await waitUntil { !rpc.commands.compactMap(\.updateThread).isEmpty }
        store.markThreadUnread("b")
        await waitUntil { rpc.commands.compactMap(\.updateThread).count == 2 }
        let updates = rpc.commands.compactMap(\.updateThread)
        #expect(updates.map(\.thread) == ["a", "b"])
        #expect(updates.map(\.read) == [true, false])
    }

    /// Editing a sent prompt starts a fork draft before its turn with the
    /// prompt's text, comments and images, and makes nothing until it is
    /// sent; sending forks and delivers in one keyed command.
    @Test
    func editingAPromptDraftsAForkBeforeItsTurnThatSendingMakes() async throws {
        let suiteName = "EditPromptForkTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = ThreadFixtures.summary(id: "a", title: "a", cwd: "/tmp/project", agent: ("codex", "Codex"))
        let rpc = MockThreadRPCClient(threads: [source], turns: ["a": [
            ThreadFixtures.turn(id: "turn-1", entries: [ThreadFixtures.entry(ref: "p1", kind: .userMessage, text: "first")]),
            ThreadFixtures.turn(id: "turn-2", entries: [ThreadFixtures.entry(ref: "p2", kind: .userMessage, text: "long")]),
        ]])
        rpc.supportsImages = true
        rpc.attachmentData["image-1"] = onePixelPNG
        let store = ThreadStore(rpc: rpc)
        await store.start()
        store.selectThread("a")
        await waitUntil { store.subscribedThreadIDs.contains("a") }
        let drafts = ThreadDraftStore(defaults: defaults)
        let chat = ChatPromptModel(store: store, draftStore: drafts, threadID: "a")
        var prompt = ThreadFixtures.entry(
            ref: "p2", kind: .userMessage, text: "Make it shorter",
            attachments: [
                mai.Attachment(
                    meta: nil, annotations: nil, data: nil, description: nil, id: "image-1",
                    kind: MaidAttachmentKind.image.rawValue, mimeType: "image/png", name: "shot.png",
                    resourceMeta: nil, size: nil, title: nil, uri: nil
                )
            ])
        prompt.annotations = [
            PromptAnnotation(id: "comment-1", messageID: "reply-1", note: "Shorter", quote: "a long answer", role: "assistant")
        ]

        #expect(await chat.fork(at: .before(turnID: "turn-2"), editing: ChatMessage(turnID: "turn-2", entry: prompt)))
        #expect(rpc.commands.isEmpty)
        #expect(rpc.forkPreviews.map(\.through) == ["turn-1"])
        let fork = try #require(drafts.activeFork)
        #expect(fork.sourceThreadID == "a" && fork.throughTurnID == "turn-1" && fork.agentID == "codex" && fork.native)

        let model = DraftPromptModel(store: store, draftStore: drafts)
        model.activate()
        model.configureInitialSelection()
        await waitUntil { !model.attachments.isEmpty && model.attachments.allSatisfy { !$0.isProcessing } }
        #expect(model.selectedProviderID == "codex" && model.forksOwnAgent)
        #expect(model.prompt == "Make it shorter")
        #expect(model.annotations.map(\.quote) == ["a long answer"])
        #expect(model.canSend)

        let draftID = try #require(drafts.activeDraftThreadID)
        await model.send()
        let command = try #require(rpc.commands.first { $0.forkThread != nil })
        let sent = try #require(command.forkThread)
        #expect(command.key == draftID)
        #expect(sent.thread == "a" && sent.through == "turn-1" && sent.agent == nil)
        #expect(sent.prompt.text == "Make it shorter")
        #expect(sent.prompt.annotations?.map(\.note) == ["Shorter"])
        #expect(sent.prompt.attachments?.map(\.mimeType) == ["image/png"])
        #expect(store.selectedThreadID == "created-1")
        #expect(drafts.activeFork == nil)
    }

    /// A send that failed without an answer may have reached the daemon:
    /// sending the same message again carries the same key, so it lands once;
    /// an edited message is a new one.
    @Test
    func resendingAnUnansweredMessageCarriesItsKey() async throws {
        let suite = "ResendKey-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = MockThreadRPCClient(threads: [makeSummary("a")])
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let model = ChatPromptModel(store: store, draftStore: ThreadDraftStore(defaults: defaults), threadID: "a")
        model.text = "Once"
        rpc.commandFailuresRemaining = 1
        await model.send(.standard)
        #expect(model.errorMessage != nil)
        await model.send(.standard)
        model.text = "Edited"
        rpc.commandFailuresRemaining = 1
        await model.send(.standard)
        model.text = "Edited again"
        await model.send(.standard)
        let keys = rpc.commands.filter { $0.deliver != nil }.map(\.key)
        #expect(keys.count == 4)
        #expect(keys[0] != nil && keys[0] == keys[1])
        #expect(keys[2] != keys[1] && keys[3] != keys[2])
    }

    /// Taking back a waiting prompt puts it in the composer ahead of what was
    /// typed since, with its comments; another agent's message is only
    /// removed.
    @Test
    func cancellingAWaitingPromptReturnsItToTheComposer() async throws {
        let suite = "CancelReturns-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = MockThreadRPCClient(threads: [makeSummary("a")])
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let model = ChatPromptModel(store: store, draftStore: ThreadDraftStore(defaults: defaults), threadID: "a")
        func waiting(_ id: String, kind: MaidDeliveryKind, text: String) -> DeliveryView {
            DeliveryView(
                annotations: [PromptAnnotation(id: "c-\(id)", messageID: "m", note: "why", quote: "this", role: "assistant")],
                answers: nil, attachments: nil, createdAt: Date(),
                from: ActorView(kind: kind == .prompt ? "device" : "agent", name: "", participant: nil, thread: nil),
                id: id, kind: kind.rawValue, mode: MaidDeliveryMode.queue.rawValue, position: 1, reason: nil,
                state: MaidDeliveryState.queued.rawValue, text: text, to: "p", turn: nil
            )
        }
        model.text = "typed since"
        await model.cancel(waiting("d1", kind: .prompt, text: "Do the thing"))
        #expect(rpc.commands.compactMap(\.cancelDelivery).map(\.delivery) == ["d1"])
        #expect(model.text == "Do the thing\n\ntyped since")
        #expect(model.annotations.map(\.quote) == ["this"])

        await model.cancel(waiting("d2", kind: .message, text: "From another agent"))
        #expect(rpc.commands.compactMap(\.cancelDelivery).map(\.delivery) == ["d1", "d2"])
        #expect(model.text == "Do the thing\n\ntyped since")
    }

    /// An agent that can't fork its own session is handed the conversation
    /// in the first message: the draft's composer starts with the summary,
    /// and sending starts that agent with what is in it.
    @Test
    func aForkWithoutANativeSessionStartsFromTheEditableSummary() async throws {
        let suiteName = "SummaryForkTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = ThreadFixtures.summary(id: "a", title: "a", cwd: "/tmp/project", agent: ("codex", "Codex"))
        let rpc = MockThreadRPCClient(threads: [source], turns: ["a": [
            ThreadFixtures.turn(id: "turn-1", entries: [ThreadFixtures.entry(ref: "p1", kind: .userMessage, text: "first")]),
        ]])
        rpc.forkPreviewResult = ForkPreview(native: false, summary: "Here is the conversation so far:\n\nUser: first\n\n")
        let store = ThreadStore(rpc: rpc)
        await store.start()
        store.selectThread("a")
        await waitUntil { store.subscribedThreadIDs.contains("a") }
        let drafts = ThreadDraftStore(defaults: defaults)
        let chat = ChatPromptModel(store: store, draftStore: drafts, threadID: "a")

        #expect(await chat.fork(at: .latest))
        #expect(rpc.forkPreviews.map(\.through) == ["turn-1"])
        let model = DraftPromptModel(store: store, draftStore: drafts)
        model.activate()
        model.configureInitialSelection()
        #expect(!model.forksOwnAgent)
        #expect(model.prompt == "Here is the conversation so far:\n\nUser: first\n\n")
        model.prompt += "Now the tests."
        await model.send()
        let sent = try #require(rpc.commands.compactMap(\.forkThread).first)
        #expect(sent.agent?.instance == "codex" && sent.through == "turn-1")
        #expect(sent.prompt.text == "Here is the conversation so far:\n\nUser: first\n\nNow the tests.")
    }

    @Test
    func annotationSendRetainsFailedDraftAndEditsMadeDuringSuccessfulSend() async throws {
        let suite = "AnnotationSendQA-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = MockThreadRPCClient(threads: [makeSummary("a")])
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let drafts = ThreadDraftStore(defaults: defaults)
        let model = ChatPromptModel(store: store, draftStore: drafts, threadID: "a")
        let annotations = ChatAnnotationModel()
        annotations.show(threadID: "a", draftStore: drafts)
        annotations.beginComment(quote: "Original quote", messageID: "message-a", role: "assistant")
        annotations.addEditorDraft()
        let originalID = try #require(annotations.annotations.first?.id)
        #expect(model.canSend)
        rpc.commandFailuresRemaining = 1
        await model.send(.standard)
        #expect(annotations.annotations.first?.id == originalID)
        #expect(model.errorMessage != nil)
        #expect(!model.isSending)

        rpc.shouldBlockCommands = true
        let sending = Task { await model.send(.standard) }
        await waitUntil { rpc.commands.filter { $0.deliver != nil }.count == 2 }
        #expect(model.isSending)
        annotations.beginComment(quote: "New quote", messageID: "message-b", role: "assistant")
        annotations.addEditorDraft()
        model.text = "Next prompt"
        rpc.resumeCommands()
        await sending.value

        let sent = try #require(rpc.commands.last?.deliver?.body)
        #expect(sent.text == nil)
        #expect(sent.annotations?.map(\.id) == [originalID])
        #expect(annotations.annotations.map(\.quote) == ["New quote"])
        #expect(model.text == "Next prompt")
        #expect(!model.isSending)
    }

    @Test
    func unsentAnnotationsAndAttachmentsStayWithTheirChat() async throws {
        let suite = "ChatDraftOwnershipQA-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = MockThreadRPCClient(threads: [makeSummary("a"), makeSummary("b")])
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let drafts = ThreadDraftStore(defaults: defaults)
        let annotations = ChatAnnotationModel()

        annotations.show(threadID: "a", draftStore: drafts)
        annotations.beginComment(quote: "Quote A 雪", messageID: "message-a", role: "assistant")
        annotations.editorDraft?.note = "Note A 🧪"
        annotations.addEditorDraft()
        let image = FileManager.default.temporaryDirectory
            .appending(path: "draft-ownership-\(UUID().uuidString).png")
        try writeOnePixelPNG(to: image)
        defer { try? FileManager.default.removeItem(at: image) }
        let chatA = ChatPromptModel(store: store, draftStore: drafts, threadID: "a")
        await chatA.addImages(from: [image])
        let attachmentID = try #require(chatA.attachments.first?.id)

        annotations.show(threadID: "b", draftStore: drafts)
        #expect(annotations.annotations.isEmpty)
        #expect(ChatPromptModel(store: store, draftStore: drafts, threadID: "b").attachments.isEmpty)
        annotations.beginComment(quote: "Quote B", messageID: "message-b", role: "assistant")
        annotations.addEditorDraft()
        annotations.beginComment(quote: "Cancelled in B", messageID: "message-b", role: "assistant")

        annotations.show(threadID: "a", draftStore: drafts)
        #expect(annotations.editorDraft == nil)
        #expect(annotations.annotations.map(\.quote) == ["Quote A 雪"])
        #expect(annotations.annotations.first?.note == "Note A 🧪")
        let returnedA = ChatPromptModel(store: store, draftStore: drafts, threadID: "a")
        #expect(returnedA.attachments.map(\.id) == [attachmentID])

        // Pending annotations survive relaunch with the text draft.
        drafts.flushPendingSave()
        let relaunched = ThreadDraftStore(defaults: defaults)
        #expect(relaunched.annotations(for: "a").map(\.messageID) == ["message-a"])
        #expect(relaunched.annotations(for: "b").map(\.quote) == ["Quote B"])

        // A send that completes after switching clears only what it submitted
        // from its own chat.
        let submittedID = try #require(annotations.annotations.first?.id)
        returnedA.removeAttachment(id: attachmentID)
        #expect(ChatPromptModel(store: store, draftStore: drafts, threadID: "a").attachments.isEmpty)
        returnedA.text = "Accepted 雪"
        rpc.shouldBlockCommands = true
        let sending = Task { await returnedA.send(.standard) }
        await waitUntil { rpc.commands.contains { $0.deliver != nil } }
        annotations.show(threadID: "b", draftStore: drafts)
        rpc.resumeCommands()
        await sending.value
        let sent = try #require(rpc.commands.last?.deliver?.body)
        #expect(sent.text == "Accepted 雪")
        #expect(sent.annotations?.map(\.id) == [submittedID])
        #expect(drafts.annotations(for: "a").isEmpty)
        #expect(annotations.annotations.map(\.quote) == ["Quote B"])

        // An accepted send is persisted at once: an immediate relaunch cannot
        // offer the sent prompt again as an unsent draft.
        let relaunchedAfterSend = ThreadDraftStore(defaults: defaults)
        #expect(relaunchedAfterSend.text(for: "a").isEmpty)
        #expect(relaunchedAfterSend.annotations(for: "a").isEmpty)
        #expect(relaunchedAfterSend.annotations(for: "b").map(\.quote) == ["Quote B"])
    }

    private final class Invalidations: Sendable {
        let timeline = Mutex(false)
        let sidebar = Mutex(false)
        let text = Mutex(false)
    }

    /// Flags that flip when the selected timeline, the sidebar, or the live
    /// streaming text publishes a change.
    private func trackInvalidations(
        of store: ThreadStore, liveText: ThreadStreamingText
    ) -> Invalidations {
        let flags = Invalidations()
        withObservationTracking {
            _ = store.selectedThread
        } onChange: {
            flags.timeline.withLock { $0 = true }
        }
        withObservationTracking {
            _ = store.threads
            _ = store.selectedThreadTitle
        } onChange: {
            flags.sidebar.withLock { $0 = true }
        }
        withObservationTracking {
            _ = liveText.text
            _ = liveText.revision
        } onChange: {
            flags.text.withLock { $0 = true }
        }
        return flags
    }

    private func writeOnePixelPNG(to url: URL) throws {
        try #require(Data(base64Encoded: onePixelPNG)).write(to: url)
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

private let onePixelPNG =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

/// A daemon that answers from per-thread snapshots, records what the store
/// sends, and pushes the notifications a test scripts.
private final class MockThreadRPCClient: ThreadRPCClient {
    var onNotification: ((String, Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    private(set) var subscribedThreadIDs: [String] = []
    private(set) var unsubscribedThreadIDs: [String] = []
    /// thread.sync and thread.subscribe calls in order, as "sync a" or
    /// "subscribe a".
    private(set) var openCalls: [String] = []
    private(set) var commands: [CommandParams] = []
    private(set) var providerStartInputs: [String] = []
    /// What thread.forkPreview answers, and the previews asked for.
    var forkPreviewResult = ForkPreview(native: true, summary: nil)
    private(set) var forkPreviews: [ThreadForkPreviewParams] = []
    private(set) var providerOptionSetInputs: [ProviderOptionsSetParams] = []
    private(set) var fileSearchInputs: [WorkspaceSearchFilesParams] = []
    private var fileSearchContinuations: [Int: CheckedContinuation<WorkspaceSearchFilesResult, Error>] = [:]
    var shouldBlockSubscribe = false
    var shouldBlockUnsubscribe = false
    var shouldBlockProviderStart = false
    var shouldBlockProviderOptionSet = false
    var shouldBlockCommands = false
    /// Commands that fail as if the connection dropped before the reply.
    var commandFailuresRemaining = 0
    var threadListFailuresRemaining = 0
    var threadSubscriptionFailuresRemaining = 0
    var providerStatus = "initialized"
    var supportsImages = false
    /// Base64 image data by attachment id.
    var attachmentData: [String: String] = [:]
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
        [(continuation: CheckedContinuation<ThreadSnapshot, Never>, snapshot: ThreadSnapshot)] = []
    private var unsubscribeContinuations: [CheckedContinuation<Void, Never>] = []
    private var providerStartContinuations: [CheckedContinuation<Void, Never>] = []
    private var providerOptionSetContinuations: [CheckedContinuation<Void, Never>] = []
    private var commandContinuations: [CheckedContinuation<Void, Never>] = []
    private let listSnapshot: [ThreadSummary]
    private var snapshotsByID: [String: ThreadSnapshot]
    /// The thread a CreateThread or ForkThread made, by the command's key,
    /// as the daemon's receipts keep them.
    private var createdByKey: [String: String] = [:]
    private var uploads = 0

    init(threads: [ThreadSummary], turns: [String: [TurnView]] = [:]) {
        listSnapshot = threads
        snapshotsByID = Dictionary(
            uniqueKeysWithValues: threads.map { summary in
                (summary.id, makeSnapshot(summary, turns: turns[summary.id]))
            })
    }

    func connect() {}

    func disconnect() {}

    func checkConnection() {}

    func searchWorkspaceFiles(_ input: WorkspaceSearchFilesParams) async throws -> WorkspaceSearchFilesResult {
        let index = fileSearchInputs.count
        fileSearchInputs.append(input)
        return try await withCheckedThrowingContinuation { continuation in
            fileSearchContinuations[index] = continuation
        }
    }

    func completeFileSearch(_ index: Int, result: Result<WorkspaceSearchFilesResult, Error>) {
        fileSearchContinuations.removeValue(forKey: index)?.resume(with: result)
    }

    func cancelFileSearches() {
        let pending = fileSearchContinuations.values
        fileSearchContinuations.removeAll()
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }

    func subscribeThreadList() async throws -> ThreadListItem {
        if threadListFailuresRemaining > 0 {
            threadListFailuresRemaining -= 1
            onDisconnect?(MockError.disconnected)
            throw MockError.disconnected
        }
        return ThreadListItem(
            kind: MaidThreadListKind.snapshot.rawValue, removed: nil, seq: 0, thread: nil, threads: listSnapshot)
    }

    func syncThread(_ threadID: String) async throws {
        openCalls.append("sync \(threadID)")
    }

    func subscribeThread(_ threadID: String) async throws -> ThreadSnapshot {
        openCalls.append("subscribe \(threadID)")
        subscribedThreadIDs.append(threadID)
        if threadSubscriptionFailuresRemaining > 0 {
            threadSubscriptionFailuresRemaining -= 1
            throw MockError.subscriptionFailed
        }
        guard let snapshot = snapshotsByID[threadID] else {
            throw MockError.missingThread(threadID)
        }
        if shouldBlockSubscribe {
            return await withCheckedContinuation { continuation in
                subscribeContinuations.append((continuation, snapshot))
            }
        }
        return snapshot
    }

    func unsubscribeThread(_ threadID: String) async throws {
        unsubscribedThreadIDs.append(threadID)
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
            optionsSessionID: "options-session-1",
            skills: nil
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
            optionsSessionID: input.optionsSessionID,
            skills: nil
        )
    }

    func resumeProviderStarts() {
        shouldBlockProviderStart = false
        resumeAll(&providerStartContinuations)
    }

    func resumeProviderOptionSets() {
        shouldBlockProviderOptionSet = false
        resumeAll(&providerOptionSetContinuations)
    }

    func forkPreview(_ input: ThreadForkPreviewParams) async throws -> ForkPreview {
        forkPreviews.append(input)
        return forkPreviewResult
    }

    func uploadAttachment(_ data: String) async throws -> String {
        uploads += 1
        return "upload-\(uploads)"
    }

    func getAttachment(_ id: String) async throws -> mai.Attachment {
        guard let data = attachmentData[id] else { throw RPCError("No such attachment") }
        return mai.Attachment(
            meta: nil, annotations: nil, data: data, description: nil,
            id: id, kind: MaidAttachmentKind.image.rawValue, mimeType: "image/png", name: nil,
            resourceMeta: nil, size: nil, title: nil, uri: nil
        )
    }

    func command(_ params: CommandParams) async throws -> CommandResult {
        commands.append(params)
        if shouldBlockCommands {
            await withCheckedContinuation { commandContinuations.append($0) }
        }
        // The daemon may have run a command whose reply was lost.
        let created = createdThread(for: params)
        if commandFailuresRemaining > 0 {
            commandFailuresRemaining -= 1
            throw MockError.disconnected
        }
        return CommandResult(delivery: nil, participant: nil, thread: created)
    }

    /// Makes the thread a CreateThread or ForkThread asks for, once per key.
    private func createdThread(for params: CommandParams) -> String? {
        guard params.createThread != nil || params.forkThread != nil else { return nil }
        if let key = params.key, let existing = createdByKey[key] { return existing }
        let id = "created-\(createdByKey.count + 1)"
        let title = params.createThread?.prompt?.text ?? "Untitled"
        snapshotsByID[id] = makeSnapshot(makeSummary(id, title: title), turns: nil)
        if let key = params.key { createdByKey[key] = id }
        return id
    }

    func resumeCommands() {
        shouldBlockCommands = false
        resumeAll(&commandContinuations)
    }

    func resumeUnsubscribes() {
        shouldBlockUnsubscribe = false
        resumeAll(&unsubscribeContinuations)
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
        subscribedThreadIDs.filter { $0 == threadID }.count
    }

    private func makeProvider(status: String) -> InstanceInfo {
        InstanceInfo(
            access: nil,
            auth: Auth(methods: nil, status: "authenticated"),
            capabilities: Capabilities(
                additionalDirectories: nil, auth: nil, commandCompletion: nil, delete: nil, fork: true,
                history: "native", historyVersion: 1, instructions: nil, logout: nil, mcp: nil, messageIDS: nil,
                promptContent: supportsImages
                    ? PromptContentCapabilities(audio: nil, embeddedContext: nil, image: true)
                    : nil,
                rename: nil, resume: nil, sessions: nil, steer: nil, subagents: nil
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

    private func publish<Params: Encodable>(_ method: String, _ params: Params) throws {
        onNotification?(method, try newJSONEncoder().encode(MockNotification(params: params)))
    }

    private func sendEvent(_ event: ThreadEvent) throws {
        try publish(MaidRPCMethod.threadEvent, event)
    }

    /// An entry of the thread's turn `turn-<thread>`, which runs.
    func sendEntry(
        threadID: String, ref: String, kind: MaidItemKind, text: String? = nil,
        status: MaidItemStatus = .completed, seq: Int
    ) throws {
        try sendEvent(ThreadFixtures.event(
            .entry, thread: threadID, seq: seq,
            turn: ThreadFixtures.turn(id: "turn-\(threadID)", state: .running, entries: []),
            entry: ThreadFixtures.entry(ref: ref, kind: kind, text: text, status: status)))
    }

    func sendText(threadID: String, ref: String, text: String, seq: Int) throws {
        try sendEvent(ThreadFixtures.event(
            .text, thread: threadID, seq: seq,
            text: TextAppend(entry: ref, stream: "", text: text, turn: "turn-\(threadID)")))
    }

    func sendTurn(threadID: String, state: MaidTurnState, seq: Int) throws {
        try sendEvent(ThreadFixtures.event(
            .turn, thread: threadID, seq: seq,
            turn: ThreadFixtures.turn(id: "turn-\(threadID)", state: state, entries: [])))
    }

    func sendSummary(_ summary: ThreadSummary, seq: Int) throws {
        try sendEvent(ThreadFixtures.event(.thread, thread: summary.id, seq: seq, summary: summary))
    }

    func sendListUpsert(_ summary: ThreadSummary, seq: Int) throws {
        try publish(
            MaidRPCMethod.threadList,
            ThreadListItem(kind: MaidThreadListKind.upsert.rawValue, removed: nil, seq: seq, thread: summary, threads: nil))
    }

    private func resumeAll(_ continuations: inout [CheckedContinuation<Void, Never>]) {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
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

private func makeSummary(
    _ id: String, title: String? = nil, status: MaidThreadStatus = .idle, updatedAt: Date = .now
) -> ThreadSummary {
    ThreadFixtures.summary(
        id: id, title: title ?? id, agent: ("codex", "Codex"), status: status, updatedAt: updatedAt)
}

/// A running thread's snapshot shows its running turn.
private func makeSnapshot(_ summary: ThreadSummary, turns: [TurnView]?) -> ThreadSnapshot {
    let turns = turns ?? (summary.threadStatus == .running
        ? [ThreadFixtures.turn(id: "turn-\(summary.id)", participant: summary.participants[0].id, state: .running, entries: [])]
        : [])
    return ThreadSnapshot(
        children: [], older: nil, participants: [ThreadFixtures.participant(of: summary)], plan: [], queue: [],
        requests: [], seq: 1, thread: summary, turns: turns
    )
}
