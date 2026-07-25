import Foundation
import Observation

struct ACPAgentChoice: Identifiable {
    let id: String
    let name: String
}

@Observable
final class ThreadStore {
    static let maximumReconnectAttempts = 5

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
    private(set) var registryAgents: [ACPRegistryAgent] = []
    var onProviderOptionsUpdated: ((ProviderOptionsResult) -> Void)?
    var onProviderOptionsInvalidated: ((ProviderOptionsInvalidated) -> Void)?

    var nativeProviders: [InstanceInfo] {
        providers
            .filter { !isACPProvider($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var acpAgentChoices: [ACPAgentChoice] {
        let runningAgents = providers.filter(isACPProvider).map {
            ACPAgentChoice(id: $0.instanceID, name: $0.name)
        }
        let runningIDs = Set(runningAgents.map(\.id))
        let registryChoices = registryAgents.compactMap { agent -> ACPAgentChoice? in
            guard !runningIDs.contains(agent.instanceID) else { return nil }
            return ACPAgentChoice(
                id: agent.instanceID,
                name: agent.name
            )
        }
        return (runningAgents + registryChoices).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var hasACPProvider: Bool {
        !acpAgentChoices.isEmpty
    }

    var recentWorkingDirectories: [String] {
        var seen: Set<String> = []
        return threads.compactMap { thread in
            guard let cwd = thread.cwd, seen.insert(cwd).inserted else { return nil }
            return cwd
        }
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
        guard let selectedThreadID else { return nil }
        return sessionsByID[selectedThreadID]?.thread
    }

    private let rpc: any ThreadRPCClient
    private let cachePolicy: CachePolicy
    private let now: () -> Date
    private var sessionsByID: [String: ThreadSession] = [:]
    private var isStarted = false
    private var lastThreadListSequence = 0
    private var isLoadingThreadListSnapshot = false
    private var bufferedThreadListItems: [ThreadListStreamItem] = []
    private var subscriptionTasks: [String: SubscriptionTask] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?

    init() {
        rpc = RPCClient()
        cachePolicy = CachePolicy()
        now = Date.init
    }

    init(
        rpc: any ThreadRPCClient,
        cachePolicy: CachePolicy = CachePolicy(),
        now: @escaping () -> Date = Date.init
    ) {
        self.rpc = rpc
        self.cachePolicy = cachePolicy
        self.now = now
    }

    #if DEBUG
    init(
        previewThreads: [ThreadListEntry],
        selectedThread: Thread? = nil,
        providers: [InstanceInfo] = [],
        registryAgents: [ACPRegistryAgent] = []
    ) {
        rpc = RPCClient()
        cachePolicy = CachePolicy()
        now = Date.init
        threads = previewThreads
        self.providers = providers
        self.registryAgents = registryAgents
        selectedThreadID = selectedThread?.id
        if let selectedThread {
            var session = ThreadSession(thread: selectedThread)
            session.subscriptionState = .visible
            session.shouldRestoreAfterReconnect = true
            sessionsByID[selectedThread.id] = session
        }
        connectionState = .connected
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
            registryAgents = (try? await rpc.listRegistryAgents()) ?? []

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
            if let thread = sessionsByID[selectedThreadID]?.thread,
               sessionsByID[selectedThreadID]?.subscriptionState.isSubscribed == true,
               thread.session == nil,
               thread.latestTurn == nil {
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
        registryAgents.contains { $0.instanceID == providerID }
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

    func startThread(_ input: Command) async throws {
        guard let threadID = input.threadID else {
            throw RPCError(code: nil, message: "Starting a chat requires a thread ID", data: nil)
        }
        _ = try await rpc.dispatchCommand(input)
        selectThread(threadID)
        await subscriptionTasks[threadID]?.task.value
    }

    func retryFailedTurn(threadID: String) async throws {
        _ = try await rpc.dispatchCommand(
            command(
                type: "thread.turn.retry",
                threadID: threadID
            )
        )
    }

    func startNewDraft() {
        selectThread(nil)
    }

    func selectThread(_ id: String?) {
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

        performSubscriptionMaintenance(at: timestamp)
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
        registryAgents.contains { $0.instanceID == provider.instanceID }
            || provider.driver == "acp"
    }

    private func resolveProvider(_ requestedID: String?) async throws -> String {
        let preferredID = requestedID ?? providers.first?.instanceID ?? registryAgents.first?.instanceID

        if let provider = providers.first(where: { $0.instanceID == preferredID }) {
            guard provider.status != "initialized" else { return provider.instanceID }
            let started = try await rpc.startProvider(provider.instanceID)
            providers.removeAll { $0.instanceID == started.instanceID }
            providers.append(started)
            return started.instanceID
        }

        if let agent = registryAgents.first(where: {
            $0.instanceID == preferredID || $0.id == preferredID
        }) {
            let started = try await rpc.startRegistryAgent(agent.id)
            providers.removeAll { $0.instanceID == started.instanceID }
            providers.append(started)
            return started.instanceID
        }

        throw RPCError(code: nil, message: "No agent is available", data: nil)
    }

    private func command(
        type: String,
        threadID: String,
        title: String? = nil,
        providerInstanceID: String? = nil,
        cwd: String? = nil,
        message: CommandMessage? = nil,
        configSelections: [ConfigOptionSelection]? = nil,
        commandID: String = UUID().uuidString
    ) -> Command {
        Command(
            commandID: commandID,
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
            title: title,
            turnID: nil,
            type: type,
            value: nil
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
            guard item.kind == "snapshot",
                  let snapshot = item.snapshot,
                  snapshot.thread.id == id else {
                throw ThreadStoreError.invalidSnapshot
            }

            current.thread = snapshot.thread
            current.lastSequence = snapshot.snapshotSequence
            current.shouldRestoreAfterReconnect = true
            sessionsByID[id] = current
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
              let thread = sessionsByID[id]?.thread,
              thread.session == nil,
              thread.latestTurn == nil else {
            return
        }
        do {
            _ = try await rpc.dispatchCommand(
                command(type: "thread.session.prepare", threadID: id)
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
                let notification = try newJSONDecoder().decode(
                    Notification<ThreadListStreamItem>.self,
                    from: data
                )
                receiveThreadListItem(notification.params)
            case MaidRPCMethod.orchestrationSubscribeThread:
                let notification = try newJSONDecoder().decode(
                    Notification<ThreadStreamItem>.self,
                    from: data
                )
                receiveThreadItem(notification.params)
            case MaidRPCMethod.providerOptionsUpdated:
                let notification = try newJSONDecoder().decode(
                    Notification<ProviderOptionsResult>.self,
                    from: data
                )
                onProviderOptionsUpdated?(notification.params)
            case MaidRPCMethod.providerOptionsInvalidated:
                let notification = try newJSONDecoder().decode(
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
        guard item.kind == "event", let event = item.event else { return }
        applyThreadEvent(event)
    }

    private func applyThreadEvent(_ event: Event) {
        guard let threadID = event.payload.threadID,
              var session = sessionsByID[threadID],
              event.sequence > session.lastSequence,
              let thread = session.thread else { return }
        let wasProtected = session.isProtected
        session.thread = ThreadEventReducer.apply(event, to: thread)
        let protectionChanged = session.isProtected != wasProtected
        session.lastSequence = event.sequence
        sessionsByID[threadID] = session
        reconcileSubscriptionState(threadID, at: now())
        if protectionChanged {
            performSubscriptionMaintenance()
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
        guard item.kind == "snapshot", let snapshot = item.snapshot else {
            errorMessage = "maiD returned an invalid thread-list snapshot"
            isLoadingThreadListSnapshot = false
            bufferedThreadListItems.removeAll()
            return false
        }

        lastThreadListSequence = snapshot.snapshotSequence
        threads = snapshot.threads
        sortThreads()
        if let selectedThreadID,
           !snapshot.threads.contains(where: { $0.id == selectedThreadID }) {
            self.selectedThreadID = nil
            selectedThreadLoadErrorMessage = nil
            sessionsByID[selectedThreadID] = nil
        }
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

        switch item.kind {
        case "thread-upserted":
            guard let thread = item.thread else { return }
            threads.removeAll { $0.id == thread.id }
            threads.append(thread)
            sortThreads()
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

        var errorDescription: String? {
            "maiD returned an invalid authoritative thread snapshot"
        }
    }
}
