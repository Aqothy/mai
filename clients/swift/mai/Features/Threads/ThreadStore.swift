import Foundation
import Observation

struct ACPAgentChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

struct QueuedChatPrompt: Identifiable {
    let id: String
    let text: String
    let attachments: [Attachment]
}

@Observable
final class ThreadStore {
    static let maximumReconnectAttempts = 5
    /// Upper bound on one connect attempt (socket handshake through the
    /// thread-list snapshot). Without it, an unresponsive daemon can hold an
    /// attempt in flight for URLSession's default 60s handshake timeout — or
    /// forever once the socket is up — leaving the store wedged in
    /// `.connecting`, where nothing is shown and neither the retry countdown
    /// nor the Disconnected/Retry pill can ever appear.
    static let connectAttemptTimeout: Duration = .seconds(15)

    enum ConnectionState {
        case disconnected
        case connecting
        case connected
    }

    struct CachePolicy {
        var maximumInactiveSubscriptions = 5
        var inactiveSubscriptionLifetime: TimeInterval = 30 * 60
    }

    private(set) var threads: [ThreadListEntry] = []
    private(set) var selectedThreadID: String?
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var errorMessage: String?
    private(set) var selectedThreadLoadErrorMessage: String?
    private(set) var reconnectAttempt = 0
    private(set) var nextReconnectAt: Date?
    private(set) var providers: [InstanceInfo] = []
    private(set) var installedAgents: [ACPRegistryInstalledAgent] = []
    var onProviderOptionsUpdated: ((ProviderOptionsResult) -> Void)?
    var onProviderOptionsInvalidated: ((ProviderOptionsInvalidated) -> Void)?

    // Derived collections are cached stored properties rather than computed:
    // a computed property would re-filter and re-sort on every read and give
    // every reader a dependency on the whole input collection. They are
    // recomputed in rebuildProviderCaches() / noteThreadsChanged() at every
    // mutation site of `providers`, `installedAgents`, and `threads`.
    private(set) var nativeProviders: [InstanceInfo] = []
    private(set) var acpAgentChoices: [ACPAgentChoice] = []
    private(set) var recentWorkingDirectories: [String] = []
    /// Mirrors `threads.isEmpty` so chrome that only needs the empty bit does
    /// not depend on the whole collection.
    private(set) var isThreadListEmpty = true
    /// Cached title of the selected thread: the live session snapshot's title
    /// when one exists, falling back to the thread-list entry's. nil when no
    /// thread is selected.
    private(set) var selectedThreadTitle: String?

    /// Binding projection for the sidebar's List selection: reads the
    /// selected thread id and routes writes through selectThread(_:).
    var sidebarSelection: String? {
        get { selectedThreadID }
        set { selectThread(newValue) }
    }

    var isReconnectScheduled: Bool {
        nextReconnectAt != nil
    }

    var automaticReconnectsExhausted: Bool {
        connectionState == .disconnected
            && reconnectAttempt >= Self.maximumReconnectAttempts
            && !isReconnectScheduled
    }

    var selectedThread: Thread? {
        _ = selectedSessionGeneration
        guard let selectedThreadID else { return nil }
        return sessionsByID[selectedThreadID]?.thread
    }

    var selectedThreadSequence: Int {
        _ = selectedSessionGeneration
        guard let selectedThreadID else { return 0 }
        return sessionsByID[selectedThreadID]?.lastSequence ?? 0
    }

    var isSelectedThreadRestoringHistory: Bool {
        _ = selectedSessionGeneration
        guard let selectedThreadID else { return false }
        return sessionsByID[selectedThreadID]?.isRestoringHistory == true
    }

    var selectedThreadHistoryRestoreErrorMessage: String? {
        _ = selectedSessionGeneration
        guard let selectedThreadID else { return nil }
        return sessionsByID[selectedThreadID]?.historyRestoreErrorMessage
    }

    private let rpc: any ThreadRPCClient
    private let cachePolicy: CachePolicy
    private let readState: ThreadReadStateStore
    private let now: () -> Date
    // Reused across notifications: receiveNotification runs on every streamed
    // event, and a fresh JSONDecoder per frame is pure allocation.
    private let decoder = newJSONDecoder()
    // sessionsByID is deliberately outside observation: it mutates on every
    // streamed event of every subscribed thread, and @Observable treats the
    // dictionary as one unit — a hidden thread's stream would invalidate every
    // view reading the selected thread. Views observe the selected-thread
    // computed properties above, which read selectedSessionGeneration; any
    // mutation that changes what those properties return must go through
    // noteSelectedSessionChanged.
    @ObservationIgnored private var sessionsByID: [String: ThreadSession] = [:]
    private var selectedSessionGeneration = 0
    private var isStarted = false
    private var lastThreadListSequence = 0
    private var isLoadingThreadListSnapshot = false
    private var bufferedThreadListItems: [ThreadListStreamItem] = []
    private var subscriptionTasks: [String: SubscriptionTask] = [:]
    private var itemDetailsByID: [ItemDetailID: CachedItemDetail] = [:]
    private var queuedPromptsByThreadID: [String: [QueuedChatPrompt]] = [:]
    private var dispatchingQueuedPromptThreadIDs: Set<String> = []
    private var reconnectTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?

    init() {
        rpc = RPCClient()
        cachePolicy = CachePolicy()
        readState = ThreadReadStateStore()
        now = Date.init
    }

    init(
        rpc: any ThreadRPCClient,
        cachePolicy: CachePolicy = CachePolicy(),
        readState: ThreadReadStateStore = ThreadReadStateStore(defaults: nil),
        now: @escaping () -> Date = Date.init
    ) {
        self.rpc = rpc
        self.cachePolicy = cachePolicy
        self.readState = readState
        self.now = now
    }

    #if DEBUG
    init(
        previewThreads: [ThreadListEntry],
        selectedThread: Thread? = nil,
        providers: [InstanceInfo] = [],
        installedAgents: [ACPRegistryInstalledAgent] = []
    ) {
        rpc = RPCClient()
        cachePolicy = CachePolicy()
        readState = ThreadReadStateStore(defaults: nil)
        now = Date.init
        threads = previewThreads
        self.providers = providers
        self.installedAgents = installedAgents
        selectedThreadID = selectedThread?.id
        if let selectedThread {
            var session = ThreadSession(thread: selectedThread)
            session.subscriptionState = .visible
            session.shouldRestoreAfterReconnect = true
            sessionsByID[selectedThread.id] = session
        }
        connectionState = .connected
        rebuildProviderCaches()
        noteThreadsChanged()
    }
    #endif

    func start() async {
        guard !isStarted else { return }

        isStarted = true
        connectionState = .connecting
        errorMessage = nil
        selectedThreadLoadErrorMessage = nil
        isLoadingThreadListSnapshot = true
        bufferedThreadListItems.removeAll()

        rpc.onNotification = { [weak self] method, data in
            self?.receiveNotification(method: method, data: data)
        }
        rpc.onDisconnect = { [weak self] error in
            self?.handleDisconnect(error)
        }
        rpc.connect()

        // A stalled attempt fails over to the scheduled-retry countdown
        // instead of wedging silently in `.connecting`. Disconnecting fails
        // the pending snapshot request, so the catch below runs the normal
        // failure path.
        let watchdog = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.connectAttemptTimeout)
            } catch {
                return
            }
            guard let self, connectionState == .connecting else { return }
            rpc.disconnect()
        }
        defer { watchdog.cancel() }

        do {
            let item = try await rpc.subscribeThreadList()
            guard applyThreadListSnapshot(item) else {
                connectionState = .disconnected
                isStarted = false
                rpc.disconnect()
                scheduleReconnect()
                return
            }
            providers = try await rpc.listProviders()
            installedAgents = (try? await rpc.listInstalledAgents()) ?? []
            rebuildProviderCaches()

            connectionState = .connected
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempt = 0
            nextReconnectAt = nil
            await restoreSubscriptions()
        } catch {
            isLoadingThreadListSnapshot = false
            bufferedThreadListItems.removeAll()
            connectionState = .disconnected
            errorMessage = error.localizedDescription
            isStarted = false
            rpc.disconnect()
            scheduleReconnect()
        }
    }

    func retry() {
        if isStarted {
            guard connectionState == .connected, let selectedThreadID else { return }
            selectedThreadLoadErrorMessage = nil
            if let session = sessionsByID[selectedThreadID],
               session.subscriptionState.isSubscribed,
               session.canPrepareHistoryRestore {
                Task {
                    await prepareSelectedRestoredThreadIfNeeded(selectedThreadID)
                }
                return
            }
            ensureSubscribed(selectedThreadID)
            return
        }

        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        nextReconnectAt = nil
        Task {
            await start()
        }
    }

    func isACPProviderID(_ providerID: String) -> Bool {
        installedAgents.contains { $0.instanceID == providerID }
            || providers.first(where: { $0.instanceID == providerID }).map(isACPProvider) == true
    }

    func ensureProviderAvailable(_ requestedID: String) async throws -> String {
        try await resolveProvider(requestedID)
    }

    func providerSupportsConfigOptions(_ providerID: String) -> Bool {
        providers.first { $0.instanceID == providerID }?.capabilities.configOptions == true
    }

    func getProviderOptions(providerID: String, cwd: String) async throws -> ProviderOptionsResult {
        try await rpc.getProviderOptions(
            ProviderOptionsGetParams(cwd: cwd, providerInstanceID: providerID)
        )
    }

    func setProviderOption(optionsSessionID: String, optionID: String, value: JSONAny) async throws -> ProviderOptionsResult {
        try await rpc.setProviderOption(
            ProviderOptionsSetParams(optionID: optionID, optionsSessionID: optionsSessionID, value: value)
        )
    }

    /// Fetches the public ACP registry index. Network-backed; callers own
    /// loading and error presentation.
    func fetchRegistryAgents() async throws -> [ACPRegistryAgent] {
        try await rpc.listRegistryAgents()
    }

    func refreshInstalledAgents() async throws {
        installedAgents = try await rpc.listInstalledAgents()
        rebuildProviderCaches()
    }

    /// Installs (or updates) a registry agent at its current registry version.
    /// If the agent was configured before, starting or restarting it also
    /// refreshes the provider service's persisted launch command.
    func installRegistryAgent(id: String) async throws -> ACPRegistryInstalledAgent {
        let installed = try await rpc.installRegistryAgent(id)
        installedAgents.removeAll { $0.id == installed.id }
        installedAgents.append(installed)
        installedAgents.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        rebuildProviderCaches()
        if let existing = providers.first(where: { $0.instanceID == installed.instanceID }) {
            let started = try await rpc.startRegistryAgent(
                installed.id,
                restart: existing.instanceStatus == .initialized
            )
            providers.removeAll { $0.instanceID == started.instanceID }
            providers.append(started)
            rebuildProviderCaches()
        }
        return installed
    }

    /// Lists importable sessions reported by an agent, starting it first when
    /// needed. Network-backed; callers own loading and error presentation.
    func fetchProviderSessions(agentID: String) async throws -> [SessionSummary] {
        let instanceID = try await ensureProviderAvailable(agentID)
        guard let provider = providers.first(where: { $0.instanceID == instanceID }),
              provider.capabilities.sessionList == true else {
            throw RPCError(code: nil, message: "This agent does not support listing sessions", data: nil)
        }
        guard provider.capabilities.loadReplay == true || provider.capabilities.resume == true else {
            throw RPCError(code: nil, message: "This agent does not support restoring sessions", data: nil)
        }
        return try await rpc.listProviderSessions(
            ProviderListSessionsParams(cwd: nil, instanceID: instanceID)
        )
    }

    /// Imports an agent session as a thread and returns its thread id.
    /// Importing a session that was already imported returns the existing
    /// thread. The imported thread reaches `threads` through the thread-list
    /// stream; its history is replayed when it is first selected.
    func importProviderSession(agentID: String, session: SessionSummary) async throws -> String {
        let instanceID = try await ensureProviderAvailable(agentID)
        let result = try await rpc.importProviderSession(
            ProviderImportSessionParams(instanceID: instanceID, session: session)
        )
        return result.threadID
    }

    func startThread(
        threadID: String,
        providerInstanceID: String,
        cwd: String,
        message: CommandMessage,
        configSelections: [ConfigOptionSelection]
    ) async throws {
        let command = Command(
            commandID: UUID().uuidString,
            configSelections: configSelections,
            createdAt: now(),
            cwd: cwd,
            decision: nil,
            message: message,
            modelSelection: nil,
            optionID: nil,
            providerInstanceID: providerInstanceID,
            requestID: nil,
            threadID: threadID,
            title: nil,
            turnID: nil,
            type: MaidCommandType.threadStart.rawValue,
            value: nil
        )
        _ = try await rpc.dispatchCommand(command)
        prepareThreadForSelection(threadID)
        await subscriptionTasks[threadID]?.task.value
    }

    func submitTurn(
        threadID: String,
        text: String,
        attachments: [Attachment] = []
    ) async throws {
        let prompt = try validatedPrompt(
            text: text,
            attachments: attachments,
            messageID: UUID().uuidString
        )
        let isRunning = sessionsByID[threadID]?.thread?.latestTurn?.turnState == .running
        let hasQueue = !(queuedPromptsByThreadID[threadID] ?? []).isEmpty
        let isDispatchingQueue = dispatchingQueuedPromptThreadIDs.contains(threadID)

        if isRunning || hasQueue || isDispatchingQueue {
            enqueue(prompt, threadID: threadID)
        } else {
            try await dispatchTurn(threadID: threadID, prompt: prompt)
        }
    }

    func queuedPrompts(for threadID: String) -> [QueuedChatPrompt] {
        queuedPromptsByThreadID[threadID] ?? []
    }

    /// Dispatches a queued prompt into the running turn immediately, removing
    /// it from the queue once the dispatch succeeds.
    func steerQueuedPrompt(threadID: String, promptID: String) async throws {
        guard let prompt = queuedPromptsByThreadID[threadID]?
            .first(where: { $0.id == promptID }),
            !dispatchingQueuedPromptThreadIDs.contains(threadID)
        else { return }

        dispatchingQueuedPromptThreadIDs.insert(threadID)
        defer { dispatchingQueuedPromptThreadIDs.remove(threadID) }

        try await dispatchTurn(threadID: threadID, prompt: prompt)
        removeQueuedPrompt(threadID: threadID, promptID: promptID)
    }

    func removeQueuedPrompt(threadID: String, promptID: String) {
        queuedPromptsByThreadID[threadID]?.removeAll { $0.id == promptID }
        if queuedPromptsByThreadID[threadID]?.isEmpty == true {
            queuedPromptsByThreadID[threadID] = nil
            sessionsByID[threadID]?.hasQueuedPrompts = false
            reconcileSubscriptionState(threadID, at: now())
        }
        performSubscriptionMaintenance()
    }

    func promptContentCapabilities(
        for providerInstanceID: String?
    ) -> PromptContentCapabilities? {
        guard let providerInstanceID else { return nil }
        return providers.first { $0.instanceID == providerInstanceID }?
            .capabilities.promptContent
    }

    func interruptTurn(threadID: String, turnID: String) async throws {
        _ = try await rpc.dispatchCommand(
            command(
                type: MaidCommandType.threadTurnInterrupt.rawValue,
                threadID: threadID,
                turnID: turnID
            )
        )
    }

    func setThreadConfigOption(
        threadID: String,
        optionID: String,
        value: JSONAny
    ) async throws {
        _ = try await rpc.dispatchCommand(
            command(
                type: MaidCommandType.threadConfigOptionSet.rawValue,
                threadID: threadID,
                optionID: optionID,
                value: value
            )
        )
    }

    func respondToApproval(
        threadID: String,
        requestID: String,
        decision: MaidApprovalDecision,
        optionID: String?
    ) async throws {
        _ = try await rpc.dispatchCommand(
            Command(
                commandID: UUID().uuidString,
                configSelections: nil,
                createdAt: now(),
                cwd: nil,
                decision: decision.rawValue,
                message: nil,
                modelSelection: nil,
                optionID: optionID,
                providerInstanceID: nil,
                requestID: requestID,
                threadID: threadID,
                title: nil,
                turnID: nil,
                type: MaidCommandType.threadApprovalRespond.rawValue,
                value: nil
            )
        )
    }

    func itemDetail(threadID: String, item: Item) async throws -> Item {
        let id = ItemDetailID(threadID: threadID, itemID: item.id)
        let requestedSequence = currentItem(threadID: threadID, itemID: item.id)?.sequence
            ?? item.sequence
        if let requestedSequence,
           let cached = itemDetailsByID[id],
           cached.sequence == requestedSequence {
            return cached.item
        }

        while true {
            let detail = try await rpc.getItemDetail(
                GetItemDetailInput(itemID: item.id, threadID: threadID)
            )
            guard detail.id == item.id else {
                throw ThreadStoreError.invalidItemDetail
            }

            // Item events and RPC responses use independent WebSocket writes.
            // Keep reading until the detail has caught up with the row state.
            if let currentSequence = currentItem(
                threadID: threadID,
                itemID: item.id
            )?.sequence,
               let detailSequence = detail.sequence,
               detailSequence < currentSequence {
                continue
            }

            itemDetailsByID[id] = CachedItemDetail(item: detail, sequence: detail.sequence)
            return detail
        }
    }

    func startNewDraft() {
        selectThread(nil)
    }

    /// Starts an uncached selection's authoritative snapshot before navigation
    /// publishes it as the visible thread.
    func prepareThreadForSelection(_ id: String) {
        guard connectionState == .connected,
              selectedThreadID != id else {
            return
        }

        let session = sessionsByID[id] ?? ThreadSession()
        guard !session.subscriptionState.isSubscribed,
              !isSubscribing(session.subscriptionState) else {
            return
        }

        sessionsByID[id] = session
        ensureSubscribed(id)
    }

    func selectThread(_ id: String?) {
        if let id {
            readState.markRead(id)
        }
        guard selectedThreadID != id else { return }

        let timestamp = now()
        if let previousID = selectedThreadID {
            markInactive(previousID, at: timestamp)
        }

        selectedThreadID = id
        selectedThreadLoadErrorMessage = nil

        if let id {
            var session = sessionsByID[id] ?? ThreadSession()
            session.inactiveSince = nil
            if session.subscriptionState.isSubscribed {
                session.subscriptionState = .visible
            }
            sessionsByID[id] = session

            if connectionState == .connected,
               !session.subscriptionState.isSubscribed,
               !isSubscribing(session.subscriptionState) {
                ensureSubscribed(id)
            }
        }

        recomputeSelectedThreadTitle()
        performSubscriptionMaintenance(at: timestamp)
    }

    static let acpDriver = "acp"

    /// Distinct driver identifiers across the configured providers, e.g.
    /// ["acp", "claude", "codex"]. The server lists every configured provider
    /// (running or not), so this needs no inference beyond grouping by driver.
    /// Cached; recomputed in rebuildProviderCaches().
    private(set) var availableDrivers: [String] = []

    /// The thread's driver id: from its session binding once one exists,
    /// otherwise from the configured (possibly not running) instance the
    /// thread is bound to, so restored threads label their rows immediately.
    func driver(for thread: ThreadListEntry) -> String? {
        let driver = thread.session?.driver?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let driver, !driver.isEmpty { return driver }
        guard let instance = instance(for: thread) else { return nil }
        let instanceDriver = instance.driver.trimmingCharacters(in: .whitespacesAndNewlines)
        return instanceDriver.isEmpty ? nil : instanceDriver
    }

    func providerDisplayName(for thread: ThreadListEntry) -> String? {
        guard let driver = driver(for: thread) else { return nil }
        guard driver == Self.acpDriver else {
            return driver
        }
        let agentName = thread.session?.providerName ?? instance(for: thread)?.name
        guard let agentName, !agentName.isEmpty else {
            return Self.acpDriver
        }
        return "\(agentName) (ACP)"
    }

    private func instance(for thread: ThreadListEntry) -> InstanceInfo? {
        thread.providerInstanceID.flatMap { instancesByID[$0] }
    }

    func isThreadUnread(_ id: String) -> Bool {
        readState.isUnread(id)
    }

    func markThreadRead(_ id: String) {
        readState.markRead(id)
    }

    func markThreadUnread(_ id: String) {
        readState.markUnread(id)
    }

    func performSubscriptionMaintenance(at timestamp: Date? = nil) {
        let timestamp = timestamp ?? now()
        let inactive = sessionsByID.compactMap { id, session -> (String, Date)? in
            guard case .inactive = session.subscriptionState,
                  let inactiveSince = session.inactiveSince else { return nil }
            return (id, inactiveSince)
        }.sorted { left, right in
            if left.1 == right.1 {
                return left.0 < right.0
            }
            return left.1 < right.1
        }

        let expiredIDs = inactive.compactMap { id, inactiveSince in
            timestamp.timeIntervalSince(inactiveSince) >= cachePolicy.inactiveSubscriptionLifetime
                ? id
                : nil
        }
        let remaining = inactive.filter { !expiredIDs.contains($0.0) }
        let overage = max(0, remaining.count - cachePolicy.maximumInactiveSubscriptions)
        let countEvictedIDs = remaining.prefix(overage).map(\.0)

        for id in Set(expiredIDs + countEvictedIDs) {
            unsubscribe(id)
        }

        scheduleMaintenance()
    }

    private func isACPProvider(_ provider: InstanceInfo) -> Bool {
        installedAgents.contains { $0.instanceID == provider.instanceID }
            || provider.driver == "acp"
    }

    /// Instances keyed by id, including configured-but-not-running ones.
    /// Cached; recomputed in rebuildProviderCaches().
    private var instancesByID: [String: InstanceInfo] = [:]

    /// Recomputes every cache derived from `providers` and `installedAgents`.
    /// Must be called after each mutation of either input.
    private func rebuildProviderCaches() {
        instancesByID = Dictionary(
            providers.map { ($0.instanceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        nativeProviders = providers
            .filter { !isACPProvider($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let runningAgents = providers.filter(isACPProvider).map {
            ACPAgentChoice(id: $0.instanceID, name: $0.name)
        }
        let runningIDs = Set(runningAgents.map(\.id))
        let installedChoices = installedAgents.compactMap { agent -> ACPAgentChoice? in
            guard !runningIDs.contains(agent.instanceID) else { return nil }
            return ACPAgentChoice(
                id: agent.instanceID,
                name: agent.name
            )
        }
        acpAgentChoices = (runningAgents + installedChoices).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        var seenDrivers: Set<String> = []
        availableDrivers = providers.compactMap { provider -> String? in
            let driver = isACPProvider(provider)
                ? Self.acpDriver
                : provider.driver.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !driver.isEmpty, seenDrivers.insert(driver).inserted else { return nil }
            return driver
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Recomputes every cache derived from `threads`. Must be called after
    /// each mutation of the thread list.
    private func noteThreadsChanged() {
        isThreadListEmpty = threads.isEmpty
        var seen: Set<String> = []
        recentWorkingDirectories = threads.compactMap { thread in
            guard let cwd = thread.cwd, seen.insert(cwd).inserted else { return nil }
            return cwd
        }
        recomputeSelectedThreadTitle()
    }

    private func recomputeSelectedThreadTitle() {
        guard let selectedThreadID else {
            selectedThreadTitle = nil
            return
        }
        selectedThreadTitle = sessionsByID[selectedThreadID]?.thread?.title
            ?? threads.first { $0.id == selectedThreadID }?.title
    }

    private func resolveProvider(_ preferredID: String) async throws -> String {
        if let provider = providers.first(where: { $0.instanceID == preferredID }),
           provider.instanceStatus == .initialized {
            return provider.instanceID
        }

        // Installed registry metadata is canonical for cold starts. This also
        // refreshes the persisted provider command after an explicit update.
        if let agent = installedAgents.first(where: {
            $0.instanceID == preferredID || $0.id == preferredID
        }) {
            let started = try await rpc.startRegistryAgent(agent.id, restart: false)
            providers.removeAll { $0.instanceID == started.instanceID }
            providers.append(started)
            rebuildProviderCaches()
            return started.instanceID
        }

        if let provider = providers.first(where: { $0.instanceID == preferredID }) {
            let started = try await rpc.startProvider(provider.instanceID)
            providers.removeAll { $0.instanceID == started.instanceID }
            providers.append(started)
            rebuildProviderCaches()
            return started.instanceID
        }

        throw RPCError(code: nil, message: "No agent is available", data: nil)
    }

    private func validatedPrompt(
        text: String,
        attachments: [Attachment],
        messageID: String
    ) throws -> QueuedChatPrompt {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else {
            throw RPCError(
                code: nil,
                message: "Sending a message requires text or an attachment",
                data: nil
            )
        }
        return QueuedChatPrompt(id: messageID, text: text, attachments: attachments)
    }

    private func enqueue(_ prompt: QueuedChatPrompt, threadID: String) {
        queuedPromptsByThreadID[threadID, default: []].append(prompt)
        var session = sessionsByID[threadID] ?? ThreadSession()
        session.hasQueuedPrompts = true
        sessionsByID[threadID] = session
        reconcileSubscriptionState(threadID, at: now())
        dispatchNextQueuedPromptIfPossible(threadID)
    }

    private func dispatchTurn(threadID: String, prompt: QueuedChatPrompt) async throws {
        _ = try await rpc.dispatchCommand(
            command(
                type: MaidCommandType.threadTurnStart.rawValue,
                threadID: threadID,
                message: CommandMessage(
                    attachments: prompt.attachments.isEmpty ? nil : prompt.attachments,
                    messageID: prompt.id,
                    text: prompt.text
                )
            )
        )
    }

    private func dispatchNextQueuedPromptIfPossible(_ threadID: String) {
        guard connectionState == .connected,
              !dispatchingQueuedPromptThreadIDs.contains(threadID),
              let thread = sessionsByID[threadID]?.thread,
              thread.latestTurn?.turnState != .running,
              thread.session?.sessionStatus == .ready
                || thread.session?.sessionStatus == .interrupted,
              let prompt = queuedPromptsByThreadID[threadID]?.first else {
            return
        }

        let turnBeforeDispatch = thread.latestTurn?.turnID
        dispatchingQueuedPromptThreadIDs.insert(threadID)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await dispatchTurn(threadID: threadID, prompt: prompt)
                if queuedPromptsByThreadID[threadID]?.first?.id == prompt.id {
                    queuedPromptsByThreadID[threadID]?.removeFirst()
                } else {
                    queuedPromptsByThreadID[threadID]?.removeAll { $0.id == prompt.id }
                }
                dispatchingQueuedPromptThreadIDs.remove(threadID)
                if queuedPromptsByThreadID[threadID]?.isEmpty == true {
                    queuedPromptsByThreadID[threadID] = nil
                    sessionsByID[threadID]?.hasQueuedPrompts = false
                    reconcileSubscriptionState(threadID, at: now())
                }
                performSubscriptionMaintenance()

                let currentTurn = sessionsByID[threadID]?.thread?.latestTurn
                if currentTurn?.turnID != turnBeforeDispatch,
                   currentTurn?.turnState != .running {
                    dispatchNextQueuedPromptIfPossible(threadID)
                }
            } catch is CancellationError {
                dispatchingQueuedPromptThreadIDs.remove(threadID)
            } catch {
                dispatchingQueuedPromptThreadIDs.remove(threadID)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func command(
        type: String,
        threadID: String,
        message: CommandMessage? = nil,
        turnID: String? = nil,
        optionID: String? = nil,
        value: JSONAny? = nil
    ) -> Command {
        Command(
            commandID: UUID().uuidString,
            configSelections: nil,
            createdAt: now(),
            cwd: nil,
            decision: nil,
            message: message,
            modelSelection: nil,
            optionID: optionID,
            providerInstanceID: nil,
            requestID: nil,
            threadID: threadID,
            title: nil,
            turnID: turnID,
            type: type,
            value: value
        )
    }

    private func handleDisconnect(_ error: Error?) {
        guard isStarted || connectionState != .disconnected else { return }

        isStarted = false
        connectionState = .disconnected
        selectedThreadLoadErrorMessage = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        for subscriptionTask in subscriptionTasks.values {
            subscriptionTask.task.cancel()
        }
        subscriptionTasks.removeAll()
        dispatchingQueuedPromptThreadIDs.removeAll()

        for id in sessionsByID.keys {
            guard var session = sessionsByID[id] else { continue }
            session.shouldRestoreAfterReconnect = session.shouldRestoreAfterReconnect
                || session.subscriptionState != .unsubscribed
            session.subscriptionState = .unsubscribed
            session.bufferedItems.removeAll()
            sessionsByID[id] = session
        }

        if let error {
            errorMessage = error.localizedDescription
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        guard reconnectAttempt < Self.maximumReconnectAttempts else {
            nextReconnectAt = nil
            return
        }

        let attempt = reconnectAttempt + 1
        let baseDelay = min(pow(2, Double(reconnectAttempt)), 30)
        let delay = min(baseDelay * Double.random(in: 0.8...1.2), 30)
        nextReconnectAt = Date().addingTimeInterval(delay)

        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            reconnectTask = nil
            nextReconnectAt = nil
            reconnectAttempt = attempt
            await start()
        }
    }

    private func restoreSubscriptions() async {
        let timestamp = now()
        performSubscriptionMaintenance(at: timestamp)

        if let selectedThreadID {
            await subscribe(selectedThreadID)
        }

        let protectedIDs = sessionsByID.compactMap { id, session in
            id != selectedThreadID && session.isProtected ? id : nil
        }
        for id in protectedIDs {
            ensureSubscribed(id)
        }

        let inactiveIDs = sessionsByID.compactMap { id, session -> (String, Date)? in
            guard id != selectedThreadID,
                  !session.isProtected,
                  session.shouldRestoreAfterReconnect,
                  let inactiveSince = session.inactiveSince,
                  timestamp.timeIntervalSince(inactiveSince) < cachePolicy.inactiveSubscriptionLifetime else {
                return nil
            }
            return (id, inactiveSince)
        }.sorted { $0.1 > $1.1 }
            .prefix(cachePolicy.maximumInactiveSubscriptions)
            .map(\.0)

        for id in inactiveIDs {
            ensureSubscribed(id)
        }
    }

    private func ensureSubscribed(_ id: String) {
        guard connectionState == .connected else { return }
        if let session = sessionsByID[id],
           session.subscriptionState.isSubscribed || isSubscribing(session.subscriptionState) {
            return
        }
        guard subscriptionTasks[id]?.operation != .subscribe else { return }

        let previousTask = subscriptionTasks[id]?.task
        let operationID = UUID()
        let task = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            await self?.subscribe(id)
            self?.finishSubscriptionTask(id, operationID: operationID)
        }
        subscriptionTasks[id] = SubscriptionTask(
            id: operationID,
            operation: .subscribe,
            task: task
        )
    }

    private func subscribe(_ id: String) async {
        guard connectionState == .connected else { return }

        if selectedThreadID == id {
            selectedThreadLoadErrorMessage = nil
        }
        let recoveryID = UUID()
        var session = sessionsByID[id] ?? ThreadSession()
        session.subscriptionState = .subscribing(recoveryID)
        session.bufferedItems.removeAll()
        sessionsByID[id] = session

        do {
            let item = try await rpc.subscribeThread(
                SubscribeThreadInput(threadID: id)
            )
            guard connectionState == .connected,
                  var current = sessionsByID[id],
                  case .subscribing(recoveryID) = current.subscriptionState else {
                return
            }
            guard item.streamKind == .snapshot,
                  let snapshot = item.snapshot,
                  snapshot.thread.id == id else {
                throw ThreadStoreError.invalidSnapshot
            }

            removeItemDetails(for: id)
            current.thread = snapshot.thread
            current.lastSequence = snapshot.snapshotSequence
            current.shouldRestoreAfterReconnect = true
            current.historyRestorePending = snapshot.historyRestorePending == true
            sessionsByID[id] = current
            noteSelectedSessionChanged(id)
            if selectedThreadID == id {
                selectedThreadLoadErrorMessage = nil
            }
            reconcileSubscriptionState(id, at: now())

            guard var recovered = sessionsByID[id] else { return }
            let buffered = recovered.bufferedItems
            recovered.bufferedItems.removeAll()
            sessionsByID[id] = recovered
            for bufferedItem in buffered.sorted(by: threadStreamSequenceAscending) {
                applyThreadEventItem(bufferedItem)
            }
            performSubscriptionMaintenance()
            await prepareSelectedRestoredThreadIfNeeded(id)
        } catch is CancellationError {
            return
        } catch {
            guard var failed = sessionsByID[id],
                  case .subscribing(recoveryID) = failed.subscriptionState else { return }
            failed.subscriptionState = .unsubscribed
            failed.bufferedItems.removeAll()
            sessionsByID[id] = failed
            if selectedThreadID == id {
                selectedThreadLoadErrorMessage = error.localizedDescription
            }
        }
    }

    private func prepareSelectedRestoredThreadIfNeeded(_ id: String) async {
        guard connectionState == .connected,
              selectedThreadID == id,
              let session = sessionsByID[id],
              session.canPrepareHistoryRestore else {
            return
        }
        do {
            _ = try await rpc.dispatchCommand(
                command(type: MaidCommandType.threadSessionPrepare.rawValue, threadID: id)
            )
        } catch {
            if selectedThreadID == id {
                selectedThreadLoadErrorMessage = error.localizedDescription
            }
        }
    }

    private func markInactive(_ id: String, at timestamp: Date) {
        guard var session = sessionsByID[id] else { return }
        session.inactiveSince = session.isProtected ? nil : timestamp
        if session.subscriptionState.isSubscribed {
            session.subscriptionState = session.isProtected ? .protected : .inactive
        }
        sessionsByID[id] = session
    }

    private func reconcileSubscriptionState(_ id: String, at timestamp: Date) {
        guard var session = sessionsByID[id],
              session.subscriptionState.isSubscribed || isSubscribing(session.subscriptionState) else {
            return
        }

        if selectedThreadID == id {
            session.subscriptionState = .visible
            session.inactiveSince = nil
        } else if session.isProtected {
            session.subscriptionState = .protected
            session.inactiveSince = nil
        } else {
            if case .protected = session.subscriptionState {
                session.inactiveSince = timestamp
            } else {
                session.inactiveSince = session.inactiveSince ?? timestamp
            }
            session.subscriptionState = .inactive
        }
        sessionsByID[id] = session
    }

    private func unsubscribe(_ id: String) {
        guard var session = sessionsByID[id],
              session.subscriptionState.isSubscribed else { return }

        session.subscriptionState = .unsubscribed
        session.shouldRestoreAfterReconnect = false
        sessionsByID[id] = session
        removeItemDetails(for: id)

        guard connectionState == .connected else { return }
        let previousTask = subscriptionTasks[id]?.task
        let operationID = UUID()
        let task = Task { [weak self] in
            await previousTask?.value
            guard let self, !Task.isCancelled else { return }
            try? await rpc.unsubscribeThread(
                SubscribeThreadInput(threadID: id)
            )
            finishSubscriptionTask(id, operationID: operationID)
        }
        subscriptionTasks[id] = SubscriptionTask(
            id: operationID,
            operation: .unsubscribe,
            task: task
        )
    }

    private func finishSubscriptionTask(_ id: String, operationID: UUID) {
        guard subscriptionTasks[id]?.id == operationID else { return }
        subscriptionTasks[id] = nil
    }

    private func removeItemDetails(for threadID: String) {
        itemDetailsByID = itemDetailsByID.filter { $0.key.threadID != threadID }
    }

    private func scheduleMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = nil

        guard connectionState == .connected else { return }
        let timestamp = now()
        let nextExpiration = sessionsByID.values.compactMap { session -> Date? in
            guard case .inactive = session.subscriptionState,
                  let inactiveSince = session.inactiveSince else { return nil }
            return inactiveSince.addingTimeInterval(cachePolicy.inactiveSubscriptionLifetime)
        }.min()
        guard let nextExpiration else { return }

        let delay = max(0, nextExpiration.timeIntervalSince(timestamp))
        maintenanceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            self?.performSubscriptionMaintenance()
        }
    }

    private func receiveNotification(method: String, data: Data) {
        do {
            switch method {
            case MaidRPCMethod.orchestrationSubscribeThreadList:
                let notification = try decoder.decode(
                    Notification<ThreadListStreamItem>.self,
                    from: data
                )
                receiveThreadListItem(notification.params)
            case MaidRPCMethod.orchestrationSubscribeThread:
                let notification = try decoder.decode(
                    Notification<ThreadStreamItem>.self,
                    from: data
                )
                receiveThreadItem(notification.params)
            case MaidRPCMethod.providerOptionsUpdated:
                let notification = try decoder.decode(
                    Notification<ProviderOptionsResult>.self,
                    from: data
                )
                onProviderOptionsUpdated?(notification.params)
            case MaidRPCMethod.providerOptionsInvalidated:
                let notification = try decoder.decode(
                    Notification<ProviderOptionsInvalidated>.self,
                    from: data
                )
                onProviderOptionsInvalidated?(notification.params)
            default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func receiveThreadItem(_ item: ThreadStreamItem) {
        guard let threadID = item.event?.payload.threadID,
              var session = sessionsByID[threadID] else { return }
        if case .subscribing = session.subscriptionState {
            session.bufferedItems.append(item)
            sessionsByID[threadID] = session
        } else {
            applyThreadEventItem(item)
        }
    }

    private func applyThreadEventItem(_ item: ThreadStreamItem) {
        guard item.streamKind == .event, let event = item.event else { return }
        applyThreadEvent(event)
    }

    private func applyThreadEvent(_ event: Event) {
        guard let threadID = event.payload.threadID else { return }
        let hadActiveTurn = hasActiveTurn(sessionsByID[threadID])
        // Straight through the subscript: a local copy of the session would
        // defeat copy-on-write and duplicate the timeline on every chunk.
        guard let result = sessionsByID[threadID]?.apply(event), result.applied else { return }
        noteSelectedSessionChanged(threadID)
        updateReadState(
            for: event,
            threadID: threadID,
            hadActiveTurn: hadActiveTurn,
            hasActiveTurn: hasActiveTurn(sessionsByID[threadID])
        )
        if result.protectionChanged {
            reconcileSubscriptionState(threadID, at: now())
            performSubscriptionMaintenance()
        }
        dispatchNextQueuedPromptIfPossible(threadID)
    }

    /// Invalidates observers of the selected-thread computed properties when a
    /// mutation touched the selected session. Mutations of other sessions
    /// intentionally invalidate nothing.
    private func noteSelectedSessionChanged(_ id: String) {
        if id == selectedThreadID {
            selectedSessionGeneration &+= 1
            recomputeSelectedThreadTitle()
        }
    }

    private func hasActiveTurn(_ session: ThreadSession?) -> Bool {
        guard let thread = session?.thread else { return false }
        if thread.session?.activeTurnID != nil {
            return true
        }
        return thread.latestTurn.map { $0.completedAt == nil } ?? false
    }

    private func currentItem(threadID: String, itemID: String) -> Item? {
        sessionsByID[threadID]?.thread?.timeline.last {
            $0.item?.id == itemID
        }?.item
    }

    private func updateReadState(
        for event: Event,
        threadID: String,
        hadActiveTurn: Bool,
        hasActiveTurn: Bool
    ) {
        guard selectedThreadID != threadID else { return }

        let completedFinalQueuedTurn = hadActiveTurn
            && !hasActiveTurn
            && queuedPromptsByThreadID[threadID]?.isEmpty != false
        let requiresAttention = event.eventType == .threadApprovalOpened
            || event.eventType == .threadSessionStatusSet
                && event.payload.session?.sessionStatus == .error

        if completedFinalQueuedTurn || requiresAttention {
            readState.markUnread(threadID)
        }
    }

    private func receiveThreadListItem(_ item: ThreadListStreamItem) {
        if isLoadingThreadListSnapshot {
            bufferedThreadListItems.append(item)
        } else {
            applyThreadListUpdate(item)
        }
    }

    private func applyThreadListSnapshot(_ item: ThreadListStreamItem) -> Bool {
        guard item.streamKind == .snapshot, let snapshot = item.snapshot else {
            errorMessage = "maiD returned an invalid thread-list snapshot"
            isLoadingThreadListSnapshot = false
            bufferedThreadListItems.removeAll()
            return false
        }

        lastThreadListSequence = snapshot.snapshotSequence
        threads = snapshot.threads
        sortThreads()
        readState.retainThreadIDs(Set(snapshot.threads.map(\.id)))
        if let selectedThreadID,
           !snapshot.threads.contains(where: { $0.id == selectedThreadID }) {
            self.selectedThreadID = nil
            selectedThreadLoadErrorMessage = nil
            sessionsByID[selectedThreadID] = nil
        }
        noteThreadsChanged()
        isLoadingThreadListSnapshot = false

        let bufferedItems = bufferedThreadListItems
        bufferedThreadListItems.removeAll()
        for bufferedItem in bufferedItems.sorted(by: streamSequenceAscending) {
            applyThreadListUpdate(bufferedItem)
        }
        return true
    }

    private func applyThreadListUpdate(_ item: ThreadListStreamItem) {
        guard let sequence = item.sequence, sequence > lastThreadListSequence else { return }
        lastThreadListSequence = sequence

        switch item.streamKind {
        case .threadUpserted:
            guard let thread = item.thread else { return }
            threads.removeAll { $0.id == thread.id }
            threads.append(thread)
            sortThreads()
            noteThreadsChanged()
        default:
            break
        }
    }

    private func sortThreads() {
        threads.sort { $0.updatedAt > $1.updatedAt }
    }

    private func isSubscribing(_ state: ThreadSession.SubscriptionState) -> Bool {
        if case .subscribing = state { return true }
        return false
    }

    private func threadStreamSequenceAscending(
        _ left: ThreadStreamItem,
        _ right: ThreadStreamItem
    ) -> Bool {
        (left.event?.sequence ?? .min) < (right.event?.sequence ?? .min)
    }

    private func streamSequenceAscending(
        _ left: ThreadListStreamItem,
        _ right: ThreadListStreamItem
    ) -> Bool {
        (left.sequence ?? .min) < (right.sequence ?? .min)
    }

    #if DEBUG
    var cachedThreadIDs: Set<String> {
        Set(sessionsByID.compactMap { $0.value.thread == nil ? nil : $0.key })
    }

    func cachedThread(for id: String) -> Thread? {
        sessionsByID[id]?.thread
    }

    var subscribedThreadIDs: Set<String> {
        Set(sessionsByID.compactMap { $0.value.subscriptionState.isSubscribed ? $0.key : nil })
    }

    var inactiveSubscribedThreadIDs: Set<String> {
        Set(sessionsByID.compactMap {
            if case .inactive = $0.value.subscriptionState { return $0.key }
            return nil
        })
    }

    var protectedSubscribedThreadIDs: Set<String> {
        Set(sessionsByID.compactMap {
            if case .protected = $0.value.subscriptionState { return $0.key }
            return nil
        })
    }
    #endif

    private struct Notification<Params: Decodable>: Decodable {
        let params: Params
    }

    private struct SubscriptionTask {
        enum Operation {
            case subscribe
            case unsubscribe
        }

        let id: UUID
        let operation: Operation
        let task: Task<Void, Never>
    }

    private enum ThreadStoreError: LocalizedError {
        case invalidSnapshot
        case invalidItemDetail

        var errorDescription: String? {
            switch self {
            case .invalidSnapshot:
                "maiD returned an invalid authoritative thread snapshot"
            case .invalidItemDetail:
                "maiD returned an invalid item detail"
            }
        }
    }
}

private struct ItemDetailID: Hashable {
    let threadID: String
    let itemID: String
}

private struct CachedItemDetail {
    let item: Item
    let sequence: Int?
}
