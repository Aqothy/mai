import Foundation
import Observation

struct ProviderChoice: Identifiable, Equatable {
    let id: String
    let name: String
    /// Where the provider runtime comes from. Several instances can share a
    /// display name, such as the built-in Codex and Codex ACP agents.
    let kind: String
    /// `name`, qualified with `kind` only when another provider shares it.
    var title: String

    init(id: String, name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
        title = name
    }
}

/// Stable text storage for one actively streaming entry. The thread detail
/// still records every chunk, while the visible leaf row observes this
/// reference directly.
@Observable
final class ThreadStreamingText {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    private(set) var text: String
    /// Cheap task identity that avoids hashing the growing text on every chunk.
    private(set) var revision = 0

    init(text: String) {
        self.text = text
    }

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        text += delta
        revision += 1
    }
}

@Observable
final class ThreadStore {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    typealias ConnectionState = RPCConnectionCoordinator.State

    /// Recently viewed chats stay subscribed in the background, bounded by
    /// count and by time since they were last visible.
    private static let maximumInactiveSubscriptions = 5
    private static let inactiveSubscriptionLifetime: TimeInterval = 30 * 60

    private(set) var threads: [ThreadSummary] = []
    private(set) var selectedThreadID: String?
    private(set) var errorMessage: String?
    private(set) var selectedThreadLoadErrorMessage: String?
    private(set) var providers: [InstanceInfo] = []
    /// A question an agent asks while the user signs in to it, shown on the
    /// provider account screen until answered or the sign-in ends.
    private(set) var providerQuestion: ProviderQuestion?
    private(set) var installedAgents: [ACPRegistryInstalledAgent] = []
    var onProviderOptionsUpdated: ((ProviderOptionsResult) -> Void)?
    var onProviderOptionsInvalidated: ((ProviderOptionsInvalidated) -> Void)?

    // Derived collections are cached stored properties rather than computed:
    // a computed property would re-filter and re-sort on every read and give
    // every reader a dependency on the whole input collection. They are
    // recomputed in rebuildProviderCaches() / noteThreadsChanged() at every
    // mutation site of `providers`, `installedAgents`, and `threads`.
    private(set) var availableProviders: [ProviderChoice] = []
    private(set) var recentWorkingDirectories: [String] = []
    /// Mirrors `threads.isEmpty` so chrome that only needs the empty bit does
    /// not depend on the whole collection.
    private(set) var isThreadListEmpty = true
    /// Cached title of the selected thread: the live detail's title when one
    /// exists, falling back to the thread list's. nil when none is selected.
    private(set) var selectedThreadTitle: String?
    /// Whether the selected chat is loading its older turns.
    private(set) var isLoadingOlderTurns = false

    var connectionState: ConnectionState { connection.state }
    var nextReconnectAt: Date? { connection.nextReconnectAt }

    var selectedThread: ThreadDetail? {
        _ = selectedSessionGeneration
        guard let selectedThreadID else { return nil }
        return sessionsByID[selectedThreadID]?.detail
    }

    var selectedThreadMarkdownSegmentCache: ChatMarkdownSegmentCache? {
        _ = selectedSessionGeneration
        guard let selectedThreadID else { return nil }
        return sessionsByID[selectedThreadID]?.markdownSegmentCache
    }

    var selectedThreadTextLayoutStore: ChatTextLayoutStore? {
        _ = selectedSessionGeneration
        guard let selectedThreadID else { return nil }
        return sessionsByID[selectedThreadID]?.textLayoutStore
    }

    var selectedThreadTimelineProjection: ChatTimelineProjection? {
        _ = selectedSessionGeneration
        guard let selectedThreadID else { return nil }
        return sessionsByID[selectedThreadID]?.timelineProjection
    }

    func resetSelectedThreadTextLayoutStore() {
        guard let selectedThreadID,
            var session = sessionsByID[selectedThreadID]
        else { return }
        session.textLayoutStore.deactivateTextViewReuse()
        session.textLayoutStore = ChatTextLayoutStore()
        sessionsByID[selectedThreadID] = session
        noteSelectedSessionChanged(selectedThreadID)
    }

    private let rpc: any ThreadRPCClient
    private let connection: RPCConnectionCoordinator
    /// Chats a read command is on its way for, so a burst of updates sends
    /// one.
    @ObservationIgnored private var markingRead: Set<String> = []
    private let now: () -> Date
    // Reused across notifications: receiveNotification runs on every streamed
    // event, and a fresh JSONDecoder per frame is pure allocation.
    private let decoder = WireJSON.makeDecoder()
    // sessionsByID is deliberately outside observation: it mutates on every
    // streamed event of every subscribed thread, and @Observable treats the
    // dictionary as one unit — a hidden thread's stream would invalidate every
    // view reading the selected thread. Views observe the selected-thread
    // computed properties above, which read selectedSessionGeneration; any
    // mutation that changes what those properties return must go through
    // noteSelectedSessionChanged.
    @ObservationIgnored private var sessionsByID: [String: ThreadSession] = [:]
    private var selectedSessionGeneration = 0
    /// Stable reference models let live leaf rows update independently of the
    /// value-typed thread detail and its timeline projection, by row ID.
    @ObservationIgnored private var streamingTextByThreadID: [String: [String: ThreadStreamingText]] = [:]
    private var lastThreadListSequence = 0
    private var isLoadingThreadListSnapshot = false
    private var bufferedThreadListItems: [ThreadListItem] = []
    private var subscriptionTasks: [String: SubscriptionTask] = [:]
    /// Whole entries read on demand, by thread and row ID, with the entry
    /// revision they were read at.
    private var entryDetailsByID: [EntryDetailID: CachedEntryDetail] = [:]
    /// Counts each entry's events, so a detail read during one isn't kept.
    @ObservationIgnored private var entryRevisions: [EntryDetailID: Int] = [:]
    @ObservationIgnored private var refreshingProviderIDs: Set<String> = []
    private var maintenanceTask: Task<Void, Never>?

    convenience init() {
        self.init(rpc: RPCClient())
    }

    init(
        rpc: any ThreadRPCClient,
        connection: RPCConnectionCoordinator? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        let connection = connection ?? RPCConnectionCoordinator(rpc: rpc)
        precondition(connection.uses(rpc), "ThreadStore must use the coordinator's RPC client")
        self.rpc = rpc
        self.connection = connection
        self.now = now

        rpc.onNotification = { [weak self] method, data in
            self?.receiveNotification(method: method, data: data)
        }
        connection.register(
            prepare: { [weak self] in
                self?.prepareConnectionAttempt()
            },
            synchronize: { [weak self] in
                try await self?.synchronizeConnection()
            },
            connected: { [weak self] in
                await self?.restoreSubscriptions()
            },
            disconnected: { [weak self] error in
                self?.connectionDidDisconnect(error)
            }
        )
    }

    #if DEBUG
        init(
            previewThreads: [ThreadSummary],
            selectedThread: ThreadDetail? = nil,
            installedAgents: [ACPRegistryInstalledAgent] = []
        ) {
            let rpc = RPCClient()
            self.rpc = rpc
            connection = RPCConnectionCoordinator(rpc: rpc, initiallyConnected: true)
            now = Date.init
            threads = previewThreads
            self.installedAgents = installedAgents
            selectedThreadID = selectedThread?.id
            if let selectedThread {
                var session = ThreadSession(detail: selectedThread)
                session.subscriptionState = .visible
                session.shouldRestoreAfterReconnect = true
                sessionsByID[selectedThread.id] = session
            }
            rebuildProviderCaches()
            noteThreadsChanged()
        }
    #endif

    func start() async {
        await connection.start()
    }

    func retry() {
        guard connectionState == .connected else {
            connection.retry()
            return
        }
        guard let selectedThreadID else { return }
        selectedThreadLoadErrorMessage = nil
        ensureSubscribed(selectedThreadID)
    }

    private func prepareConnectionAttempt() {
        errorMessage = nil
        selectedThreadLoadErrorMessage = nil
        isLoadingThreadListSnapshot = true
        bufferedThreadListItems.removeAll()
    }

    private func synchronizeConnection() async throws {
        let item = try await rpc.subscribeThreadList()
        guard applyThreadListSnapshot(item) else {
            throw RPCError("maiD returned an invalid thread-list snapshot")
        }
        providers = try await rpc.listProviders()
        installedAgents = (try? await rpc.listInstalledAgents()) ?? []
        rebuildProviderCaches()
    }

    // MARK: Providers

    func providerSupportsAdditionalDirectories(_ providerID: String) -> Bool {
        providerInfo(for: providerID)?.capabilities.additionalDirectories == true
    }

    func providerInfo(for providerID: String) -> InstanceInfo? {
        if let instance = instancesByID[providerID] {
            return instance
        }
        guard
            let instanceID = installedAgents.first(where: {
                $0.id == providerID || $0.instanceID == providerID
            })?.instanceID
        else { return nil }
        return instancesByID[instanceID]
    }

    /// Whether a session the agent kept opens as a chat: it reopens sessions
    /// with their memory.
    func providerSupportsSessionImport(_ providerID: String) -> Bool {
        providerInfo(for: providerID)?.capabilities.resume == true
    }

    func providerSupportsSessionDelete(_ providerID: String) -> Bool {
        providerInfo(for: providerID)?.capabilities.delete == true
    }

    /// Starts a cold provider if needed and returns its current account state.
    func prepareProviderAccount(_ providerID: String) async throws -> InstanceInfo {
        let instanceID = try await ensureProviderAvailable(providerID)
        guard let instance = providerInfo(for: instanceID) else {
            throw RPCError("Provider account information is unavailable")
        }
        return instance
    }

    /// Re-reads provider state after an out-of-process browser or device-code
    /// login completes.
    func refreshProviderAccount(_ providerID: String) async throws -> InstanceInfo {
        providers = try await rpc.listProviders()
        rebuildProviderCaches()
        guard let instance = providerInfo(for: providerID) else {
            throw RPCError("Provider account information is unavailable")
        }
        return instance
    }

    func authenticateProvider(
        providerID: String,
        methodID: String,
        secret: String?
    ) async throws -> AuthenticationResult {
        let instanceID = try await ensureProviderAvailable(providerID)
        guard providerInfo(for: instanceID)?.capabilities.auth == true else {
            throw RPCError("This provider does not support sign in")
        }
        defer { providerQuestion = nil }
        let result = try await rpc.authenticateProvider(
            ProviderAuthenticateParams(
                instanceID: instanceID,
                methodID: methodID,
                secret: secret
            )
        )
        replaceProvider(result.instance)
        return result
    }

    func answerProviderQuestion(
        _ action: RequestAction,
        answers: [String: [String]]?
    ) async throws {
        guard let question = providerQuestion else { return }
        try await rpc.answerProviderQuestion(
            ProviderQuestionAnswerParams(
                actionID: action.id,
                answers: answers,
                requestID: question.requestID
            ))
        if providerQuestion?.requestID == question.requestID {
            providerQuestion = nil
        }
    }

    func logoutProvider(_ providerID: String) async throws -> InstanceInfo {
        let instanceID = try await ensureProviderAvailable(providerID)
        guard providerInfo(for: instanceID)?.capabilities.logout == true else {
            throw RPCError("This provider does not support sign out")
        }
        let instance = try await rpc.logoutProvider(
            ProviderInstanceParams(instanceID: instanceID)
        )
        replaceProvider(instance)
        return instance
    }

    func getProviderOptions(providerID: String, cwd: String) async throws -> ProviderOptionsResult {
        try await rpc.getProviderOptions(
            ProviderOptionsGetParams(cwd: cwd, providerInstanceID: providerID)
        )
    }

    func setProviderOption(optionsSessionID: String, optionID: String, value: JSONAny) async throws
        -> ProviderOptionsResult
    {
        try await rpc.setProviderOption(
            ProviderOptionsSetParams(
                optionID: optionID, optionsSessionID: optionsSessionID, value: value)
        )
    }

    func browseWorkspaceDirectories(
        at path: String?
    ) async throws -> WorkspaceBrowseDirectoriesResult {
        try await rpc.browseWorkspaceDirectories(
            WorkspaceBrowseDirectoriesParams(path: path)
        )
    }

    func searchWorkspaceFiles(
        _ input: WorkspaceSearchFilesParams
    ) async throws -> WorkspaceSearchFilesResult {
        try await rpc.searchWorkspaceFiles(input)
    }

    func completeCommand(_ input: ProviderCompleteCommandParams) async throws -> [CommandCompletion] {
        try await rpc.completeCommand(input)
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
    /// The daemon adopts the update on the next agent launch. A running
    /// process keeps its current version so updating cannot interrupt a turn.
    func installRegistryAgent(id: String) async throws -> ACPRegistryInstalledAgent {
        let installed = try await rpc.installRegistryAgent(id)
        upsertInstalledAgent(installed)
        return installed
    }

    /// Adds a custom ACP definition to the daemon-owned agent manifest. The
    /// provider remains cold until a thread or session action needs it.
    func addCustomACPAgent(
        _ configuration: CustomACPAgentConfiguration
    ) async throws -> ACPRegistryInstalledAgent {
        let installed = try await rpc.addCustomACPAgent(
            ACPCustomAgentAddParams(
                args: configuration.arguments.isEmpty ? nil : configuration.arguments,
                command: configuration.command,
                env: configuration.environment.isEmpty ? nil : configuration.environment,
                name: configuration.name
            )
        )
        upsertInstalledAgent(installed)
        return installed
    }

    /// Lists sessions reported by an agent, starting it first when needed.
    /// Import and delete remain independently capability-gated.
    func fetchProviderSessions(agentID: String) async throws -> [SessionSummary] {
        let instanceID = try await ensureProviderAvailable(agentID)
        guard let provider = providerInfo(for: instanceID),
            provider.capabilities.sessions == true
        else {
            throw RPCError("This agent does not support listing sessions")
        }
        return try await rpc.listProviderSessions(
            ProviderListSessionsParams(cwd: nil, instanceID: instanceID)
        )
    }

    /// Opens an agent's session as a chat and returns its thread id. A
    /// session already open as a chat returns that chat. The chat shows the
    /// agent's history once it is opened.
    func importProviderSession(agentID: String, session: SessionSummary) async throws -> String {
        let instanceID = try await ensureProviderAvailable(agentID)
        guard providerSupportsSessionImport(instanceID) else {
            throw RPCError("This agent does not support restoring sessions")
        }
        guard let cwd = session.cwd, !cwd.isEmpty else {
            throw RPCError("The agent didn't say where this session works")
        }
        let create = CreateThread(
            participant: NewParticipant(instance: instanceID, session: session.sessionID, settings: nil),
            prompt: nil,
            title: session.title,
            workspace: Workspace(additionalDirectories: session.additionalDirectories, cwd: cwd)
        )
        guard let threadID = try await command(CommandParams(createThread: create)).thread else {
            throw RPCError("maiD returned no chat for the session")
        }
        return threadID
    }

    func deleteProviderSession(agentID: String, sessionID: String) async throws {
        let instanceID = try await ensureProviderAvailable(agentID)
        guard providerSupportsSessionDelete(instanceID) else {
            throw RPCError("This agent does not support deleting sessions")
        }
        try await rpc.deleteProviderSession(
            ProviderSessionParams(instanceID: instanceID, sessionID: sessionID)
        )
    }

    // MARK: Chat state

    func threadIsRunning(_ threadID: String) -> Bool {
        sessionsByID[threadID]?.detail?.status == .running
    }

    /// The latest turn when it failed.
    private func failedTurn(_ threadID: String) -> TurnView? {
        guard let turn = sessionsByID[threadID]?.detail?.latestTurn, turn.turnState == .failed else { return nil }
        return turn
    }

    func failedTurnID(for threadID: String) -> String? {
        failedTurn(threadID)?.id
    }

    func failedTurnError(for threadID: String) -> String? {
        failedTurn(threadID)?.error
    }

    /// The chat's agent when it reports being signed out, which is the one
    /// failure the user can fix from the chat.
    func signedOutProviderID(for threadID: String) -> String? {
        guard let instance = sessionsByID[threadID]?.detail?.addressee?.instance,
            providerInfo(for: instance)?.auth.status == MaidAuthStatus.unauthenticated.rawValue
        else { return nil }
        return instance
    }

    /// Re-reads provider state after a failure, since it may be the provider
    /// refusing an unauthenticated request.
    func refreshProvidersAfterFailure() async {
        guard connectionState == .connected,
            let refreshed = try? await rpc.listProviders()
        else { return }
        providers = refreshed
        rebuildProviderCaches()
    }

    /// Why the thread's latest turn ended early, when it completed early.
    func completedTurnStopReason(for threadID: String) -> MaidStopReason? {
        guard let turn = sessionsByID[threadID]?.detail?.latestTurn,
            turn.turnState == .completed
        else { return nil }
        return turn.stopReason.flatMap(MaidStopReason.init(rawValue:))
    }

    /// The directory a thread's workspace file search, and so its file
    /// mentions, are relative to.
    func workingDirectory(forThread threadID: String) -> String? {
        sessionsByID[threadID]?.detail?.summary.workspace.cwd
            ?? threads.first { $0.id == threadID }?.workspace.cwd
    }

    /// The agent the thread talks to.
    func providerID(for thread: ThreadSummary) -> String? {
        (thread.participants.first { $0.id == thread.address } ?? thread.participants.first)?.instance
    }

    func providerDisplayName(for thread: ThreadSummary) -> String? {
        let participant = thread.participants.first { $0.id == thread.address } ?? thread.participants.first
        guard let participant else { return nil }
        let name = participant.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? participant.instance : name
    }

    func promptContentCapabilities(
        for providerInstanceID: String?
    ) -> PromptContentCapabilities? {
        guard let providerInstanceID else { return nil }
        return providerInfo(for: providerInstanceID)?.capabilities.promptContent
    }

    /// The daemon's: a turn settled since someone last read the chat, on
    /// any device.
    func isThreadUnread(_ id: String) -> Bool {
        threads.first { $0.id == id }?.attention.unread == true
    }

    func markThreadRead(_ id: String) {
        setRead(true, for: id)
    }

    func markThreadUnread(_ id: String) {
        setRead(false, for: id)
    }

    private func setRead(_ read: Bool, for id: String) {
        guard connectionState == .connected, !markingRead.contains(id) else { return }
        markingRead.insert(id)
        Task {
            defer { markingRead.remove(id) }
            // A lost one shows the chat as it was; the next view or toggle
            // sends it again.
            _ = try? await command(CommandParams(updateThread: UpdateThread(policy: nil, read: read, thread: id, title: nil)))
        }
    }

    // MARK: Commands

    /// Sends a command, keyed so a retry after a dropped connection doesn't
    /// run it twice.
    @discardableResult
    private func command(_ params: CommandParams) async throws -> CommandResult {
        var params = params
        params.key = params.key ?? UUID().uuidString
        return try await rpc.command(params)
    }

    /// Starts a chat with an agent and its first message; returns once the
    /// chat's snapshot arrived. The same key starts one chat however often
    /// it is sent.
    func startThread(
        key: String,
        providerInstanceID: String,
        cwd: String,
        additionalDirectories: [String] = [],
        body: MessageBody,
        settings: [ConfigOptionSelection]
    ) async throws -> String {
        let create = CreateThread(
            participant: NewParticipant(instance: providerInstanceID, session: nil, settings: settings.isEmpty ? nil : settings),
            prompt: try await uploadingAttachmentData(of: body),
            title: nil,
            workspace: Workspace(additionalDirectories: additionalDirectories.isEmpty ? nil : additionalDirectories, cwd: cwd)
        )
        var params = CommandParams(createThread: create)
        params.key = key
        guard let threadID = try await command(params).thread else {
            throw RPCError("maiD returned no chat")
        }
        prepareThreadSubscription(threadID)
        await subscriptionTasks[threadID]?.task.value
        return threadID
    }

    /// Sends a prompt. The daemon starts a turn with it, or, while the chat
    /// is busy, queues it for when the running turn ends or steers it into
    /// that turn. Sending again with the same `key` lands it once.
    func submitTurn(
        threadID: String,
        text: String,
        attachments: [Attachment] = [],
        annotations: [PromptAnnotation] = [],
        mode: PromptSendMode,
        key: String = UUID().uuidString
    ) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty || !annotations.isEmpty else {
            throw RPCError("Sending a message requires text, an attachment, or an annotation")
        }
        let body = try await uploadingAttachmentData(
            of: MessageBody(
                annotations: annotations.isEmpty ? nil : annotations,
                attachments: attachments.isEmpty ? nil : attachments,
                text: text.isEmpty ? nil : text
            ))
        let deliver = Deliver(
            body: body,
            mode: mode == .steer ? MaidDeliveryMode.steer.rawValue : MaidDeliveryMode.queue.rawValue,
            thread: threadID,
            to: nil,
            wantsReply: nil
        )
        var params = CommandParams(deliver: deliver)
        params.key = key
        try await command(params)
    }

    /// Uploads each attachment's data on its own and lists the attachment by
    /// ID, so a message stays small however many images it carries.
    private func uploadingAttachmentData(of body: MessageBody) async throws -> MessageBody {
        var body = body
        for index in body.attachments?.indices ?? 0..<0 {
            guard let data = body.attachments?[index].data, !data.isEmpty else { continue }
            body.attachments?[index].id = try await rpc.uploadAttachment(data)
            body.attachments?[index].data = nil
        }
        return body
    }

    /// One attachment's data, which thread snapshots leave out.
    func attachmentData(attachmentID: String) async throws -> String {
        let attachment = try await rpc.getAttachment(attachmentID)
        guard let data = attachment.data, !data.isEmpty else {
            throw RPCError("The attachment has no data")
        }
        return data
    }

    /// Messages waiting for the chat's running turn to end, and those that
    /// didn't get through.
    func queue(for threadID: String) -> [DeliveryView] {
        sessionsByID[threadID]?.detail?.queue ?? []
    }

    /// Sends a waiting message now: steered into the running turn, or as the
    /// next turn when nothing runs.
    func sendNow(delivery: String) async throws {
        try await command(CommandParams(steerDelivery: SteerDelivery(delivery: delivery)))
    }

    func cancel(delivery: String) async throws {
        try await command(CommandParams(cancelDelivery: CancelDelivery(delivery: delivery)))
    }

    /// Moves a waiting message before another, or last.
    func move(delivery: String, before: String?) async throws {
        try await command(CommandParams(moveDelivery: MoveDelivery(before: before, delivery: delivery)))
    }

    /// Sends a message again: one that didn't get through, or the prompt of
    /// the chat's failed last turn.
    func retry(delivery: String) async throws {
        guard connectionState == .connected else {
            throw RPCError("Reconnect before retrying this message")
        }
        try await command(CommandParams(retryDelivery: RetryDelivery(delivery: delivery)))
    }

    func interruptTurn(threadID: String) async throws {
        try await command(CommandParams(interrupt: Interrupt(thread: threadID)))
    }

    /// Stops the chat and every chat it started, and holds their queues.
    func stopThread(threadID: String) async throws {
        try await command(CommandParams(stop: Stop(thread: threadID)))
    }

    /// Lets a held chat's queue go on.
    func continueThread(threadID: String) async throws {
        try await command(CommandParams(commandParamsContinue: Continue(thread: threadID)))
    }

    /// Stops a background task, such as a command a tool left running. The
    /// provider then settles the entry through the thread's events.
    func stopItem(threadID: String, ref: String) async throws {
        try await command(CommandParams(stopItem: StopItem(item: ref, thread: threadID)))
    }

    /// Sets one of the agent's settings.
    func setThreadConfigOption(
        threadID: String,
        optionID: String,
        value: JSONAny
    ) async throws {
        guard let participant = sessionsByID[threadID]?.detail?.addressee else {
            throw RPCError("This chat has no agent")
        }
        let setting = ConfigOptionSelection(category: nil, optionID: optionID, value: value)
        try await command(CommandParams(updateParticipant: UpdateParticipant(participant: participant.id, setting: setting)))
    }

    /// Renames a thread. The daemon also names the provider's own session
    /// where sessions have names (Claude Code, Codex). A blank title is
    /// ignored.
    func renameThread(threadID: String, title: String) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        try await command(
            CommandParams(updateThread: UpdateThread(policy: nil, read: nil, thread: threadID, title: title))
        )
    }

    func respondToRequest(
        threadID: String,
        requestID: String,
        actionID: String,
        answers: [String: [String]]?
    ) async throws {
        let respond = Respond(action: actionID, answers: answers, request: requestID, thread: threadID, why: nil)
        try await command(CommandParams(respond: respond))
    }

    /// How a fork of a chat through a turn starts, into another agent when
    /// `agentID` names one: its agent's own session forked, or a summary of
    /// the conversation for the first message.
    func forkPreview(_ sourceThreadID: String, throughTurnID: String?, agentID: String?) async throws -> ForkPreview {
        try await rpc.forkPreview(ThreadForkPreviewParams(agent: agentID, thread: sourceThreadID, through: throughTurnID))
    }

    /// Forks a chat through a turn into a new chat that starts with `body`,
    /// and returns it once its snapshot arrived: its agent's session forked,
    /// when `agent` is nil, or `agent` starting a session of its own, whose
    /// first message, `body`, carries the conversation (`forkPreview`).
    /// `key` is the draft's.
    func forkThread(
        key: String,
        sourceThreadID: String,
        throughTurnID: String,
        agent: NewParticipant?,
        body: MessageBody
    ) async throws -> String {
        let fork = ForkThread(agent: agent, prompt: try await uploadingAttachmentData(of: body), thread: sourceThreadID, through: throughTurnID)
        var params = CommandParams(forkThread: fork)
        params.key = key
        guard let threadID = try await command(params).thread else {
            throw RPCError("maiD returned no chat for the fork")
        }
        prepareThreadSubscription(threadID)
        await subscriptionTasks[threadID]?.task.value
        return threadID
    }

    /// Loads the selected chat's turns before the oldest one it shows.
    func loadOlderTurns() async {
        guard let threadID = selectedThreadID,
            let older = sessionsByID[threadID]?.detail?.older,
            !isLoadingOlderTurns
        else { return }
        isLoadingOlderTurns = true
        defer { isLoadingOlderTurns = false }
        do {
            let page = try await rpc.threadTurns(ThreadTurnsParams(before: older, limit: nil, thread: threadID))
            guard sessionsByID[threadID]?.detail?.older == older else { return }
            sessionsByID[threadID]?.detail?.prepend(page)
            sessionsByID[threadID]?.timelineProjection.invalidateAll()
            noteSelectedSessionChanged(threadID)
        } catch is CancellationError {
            return
        } catch {
            if selectedThreadID == threadID {
                selectedThreadLoadErrorMessage = error.localizedDescription
            }
        }
    }

    /// An entry whole: a tool's full input and output, a handoff's text.
    func entryDetail(threadID: String, item: ChatItem) async throws -> Entry {
        let id = EntryDetailID(threadID: threadID, rowID: item.id)
        while true {
            let revision = entryRevisions[id, default: 0]
            if let cached = entryDetailsByID[id], cached.revision == revision {
                return cached.entry
            }
            let entry = try await rpc.threadEntry(ThreadEntryParams(ref: item.ref, thread: threadID))
            guard entry.ref == item.ref else {
                throw ThreadStoreError.invalidEntryDetail
            }
            // Entry events and RPC responses are independent writes: an
            // event during the read may be newer than what it returned.
            if entryRevisions[id, default: 0] == revision {
                entryDetailsByID[id] = CachedEntryDetail(entry: entry, revision: revision)
                return entry
            }
        }
    }

    // MARK: Selection and subscriptions

    /// Starts a snapshot without publishing selection. New-thread creation
    /// uses this to await its authoritative model before revealing the chat.
    private func prepareThreadSubscription(_ id: String) {
        guard connectionState == .connected,
            selectedThreadID != id
        else { return }

        let session = sessionsByID[id] ?? ThreadSession()
        guard !session.subscriptionState.isSubscribed,
            !isSubscribing(session.subscriptionState)
        else { return }

        sessionsByID[id] = session
        ensureSubscribed(id)
    }

    func selectThread(_ id: String?) {
        if let id, isThreadUnread(id) {
            markThreadRead(id)
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
                // Still watched, but turns may have run in the CLI meanwhile;
                // what the check finds comes back as a refresh.
                Task { [rpc] in try? await rpc.syncThread(id) }
            }
            sessionsByID[id] = session

            if !session.subscriptionState.isSubscribed,
                connectionState == .connected,
                !isSubscribing(session.subscriptionState)
            {
                ensureSubscribed(id)
            }
        }

        recomputeSelectedThreadTitle()
        performSubscriptionMaintenance(at: timestamp)
    }

    func performSubscriptionMaintenance(at timestamp: Date? = nil) {
        let timestamp = timestamp ?? now()
        let inactive = sessionsByID.compactMap { id, session -> (String, Date)? in
            guard case .inactive = session.subscriptionState,
                let inactiveSince = session.inactiveSince
            else { return nil }
            return (id, inactiveSince)
        }.sorted { left, right in
            if left.1 == right.1 {
                return left.0 < right.0
            }
            return left.1 < right.1
        }

        let expiredIDs = inactive.compactMap { id, inactiveSince in
            timestamp.timeIntervalSince(inactiveSince) >= Self.inactiveSubscriptionLifetime
                ? id
                : nil
        }
        let remaining = inactive.filter { !expiredIDs.contains($0.0) }
        let overage = max(0, remaining.count - Self.maximumInactiveSubscriptions)
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

    private func upsertInstalledAgent(_ installed: ACPRegistryInstalledAgent) {
        installedAgents.removeAll { $0.id == installed.id }
        installedAgents.append(installed)
        installedAgents.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        rebuildProviderCaches()
    }

    private func replaceProvider(_ provider: InstanceInfo) {
        providers.removeAll { $0.instanceID == provider.instanceID }
        providers.append(provider)
        rebuildProviderCaches()
    }

    /// A chat can start its agent entirely inside the daemon. Refresh the
    /// catalog once the agent is live so capability-gated controls do not
    /// keep consulting the configured instance's cold capability set.
    private func refreshProviderAfterAgentStarted(_ providerID: String) {
        guard providerInfo(for: providerID)?.instanceStatus != .initialized,
            refreshingProviderIDs.insert(providerID).inserted
        else { return }

        Task { [weak self] in
            guard let self else { return }
            defer { refreshingProviderIDs.remove(providerID) }
            guard connectionState == .connected,
                let refreshed = try? await rpc.listProviders()
            else { return }
            providers = refreshed
            rebuildProviderCaches()
        }
    }

    /// Recomputes every cache derived from `providers` and `installedAgents`.
    /// Must be called after each mutation of either input.
    private func rebuildProviderCaches() {
        instancesByID = Dictionary(
            providers.map { ($0.instanceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let nativeProviders = providers.filter { !isACPProvider($0) }.map {
            ProviderChoice(id: $0.instanceID, name: $0.name, kind: String(localized: "Built-in"))
        }
        let installedACPProviders = installedAgents.map { agent in
            ProviderChoice(
                id: agent.instanceID,
                name: agent.name,
                kind: agent.source == "custom"
                    ? String(localized: "Custom ACP")
                    : String(localized: "ACP Registry")
            )
        }
        var seenProviderIDs: Set<String> = []
        var choices = (nativeProviders + installedACPProviders).filter {
            seenProviderIDs.insert($0.id).inserted
        }.sorted {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder == .orderedSame {
                return $0.id.localizedStandardCompare($1.id) == .orderedAscending
            }
            return nameOrder == .orderedAscending
        }
        let nameCounts = Dictionary(choices.map { ($0.name, 1) }, uniquingKeysWith: +)
        for index in choices.indices where nameCounts[choices[index].name, default: 0] > 1 {
            choices[index].title = "\(choices[index].name) (\(choices[index].kind))"
        }
        availableProviders = choices
    }

    /// Recomputes every cache derived from `threads`. Must be called after
    /// each mutation of the thread list.
    private func noteThreadsChanged() {
        isThreadListEmpty = threads.isEmpty
        var seen: Set<String> = []
        recentWorkingDirectories = threads.compactMap { thread in
            let cwd = thread.workspace.cwd
            guard !cwd.isEmpty, seen.insert(cwd).inserted else { return nil }
            return cwd
        }
        recomputeSelectedThreadTitle()
    }

    private func recomputeSelectedThreadTitle() {
        guard let selectedThreadID else {
            selectedThreadTitle = nil
            return
        }
        selectedThreadTitle =
            sessionsByID[selectedThreadID]?.detail?.summary.title
            ?? threads.first { $0.id == selectedThreadID }?.title
    }

    func ensureProviderAvailable(_ preferredID: String) async throws -> String {
        if let provider = providers.first(where: { $0.instanceID == preferredID }),
            provider.instanceStatus == .initialized
        {
            return provider.instanceID
        }

        // Backend-owned installed metadata is canonical for registry and
        // custom-agent cold starts.
        if let agent = installedAgents.first(where: {
            $0.instanceID == preferredID || $0.id == preferredID
        }) {
            let started = try await rpc.startRegistryAgent(agent.id, restart: false)
            replaceProvider(started)
            return started.instanceID
        }

        if let provider = providers.first(where: { $0.instanceID == preferredID }) {
            let started = try await rpc.startProvider(provider.instanceID)
            replaceProvider(started)
            return started.instanceID
        }

        throw RPCError("No agent is available")
    }

    private func connectionDidDisconnect(_ error: (any Error)?) {
        isLoadingThreadListSnapshot = false
        bufferedThreadListItems.removeAll()
        selectedThreadLoadErrorMessage = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        for subscriptionTask in subscriptionTasks.values {
            subscriptionTask.task.cancel()
        }
        subscriptionTasks.removeAll()

        for id in sessionsByID.keys {
            guard var session = sessionsByID[id] else { continue }
            session.shouldRestoreAfterReconnect =
                session.shouldRestoreAfterReconnect
                || session.subscriptionState != .unsubscribed
            session.subscriptionState = .unsubscribed
            session.bufferedEvents.removeAll()
            sessionsByID[id] = session
        }

        if let error {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreSubscriptions() async {
        let timestamp = now()
        performSubscriptionMaintenance(at: timestamp)

        let protectedIDs = sessionsByID.compactMap { id, session in
            id != selectedThreadID && session.isProtected ? id : nil
        }

        let inactiveIDs = sessionsByID.compactMap { id, session -> (String, Date)? in
            guard id != selectedThreadID,
                !session.isProtected,
                session.shouldRestoreAfterReconnect,
                let inactiveSince = session.inactiveSince,
                timestamp.timeIntervalSince(inactiveSince)
                    < Self.inactiveSubscriptionLifetime
            else {
                return nil
            }
            return (id, inactiveSince)
        }.sorted { $0.1 > $1.1 }
            .prefix(Self.maximumInactiveSubscriptions)
            .map(\.0)

        let restoredIDs = [selectedThreadID].compactMap(\.self) + protectedIDs + inactiveIDs
        for id in restoredIDs {
            ensureSubscribed(id)
        }
        for id in restoredIDs {
            await subscriptionTasks[id]?.task.value
        }
    }

    private func ensureSubscribed(_ id: String) {
        guard connectionState == .connected else { return }
        if let session = sessionsByID[id],
            session.subscriptionState.isSubscribed || isSubscribing(session.subscriptionState)
        {
            return
        }
        guard subscriptionTasks[id]?.operation != .subscribe else { return }

        let previousTask = subscriptionTasks[id]?.task
        let operationID = UUID()
        let task = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            await self?.subscribe(id, operationID: operationID)
            self?.finishSubscriptionTask(id, operationID: operationID)
        }
        subscriptionTasks[id] = SubscriptionTask(
            id: operationID,
            operation: .subscribe,
            task: task
        )
    }

    private func subscribe(_ id: String, operationID: UUID) async {
        guard connectionState == .connected else { return }

        if selectedThreadID == id {
            selectedThreadLoadErrorMessage = nil
        }
        let recoveryID = UUID()
        var session = sessionsByID[id] ?? ThreadSession()
        session.subscriptionState = .subscribing(recoveryID)
        session.bufferedEvents.removeAll()
        sessionsByID[id] = session

        do {
            // Caught up first (turns run in the CLI, a rebuild), so the chat
            // shows as its agent's session has it; a failure leaves the
            // daemon's copy, which subscribing reports on its own.
            try? await rpc.syncThread(id)
            let snapshot = try await rpc.subscribeThread(id)
            guard connectionState == .connected,
                var current = sessionsByID[id],
                case .subscribing(recoveryID) = current.subscriptionState
            else {
                return
            }
            guard snapshot.thread.id == id else {
                throw ThreadStoreError.invalidSnapshot
            }

            replaceThreadContents(with: snapshot, session: &current)
            current.shouldRestoreAfterReconnect = true
            sessionsByID[id] = current
            noteSelectedSessionChanged(id)
            if selectedThreadID == id {
                selectedThreadLoadErrorMessage = nil
            }
            reconcileSubscriptionState(id, at: now())

            guard var recovered = sessionsByID[id] else { return }
            let buffered = recovered.bufferedEvents
            recovered.bufferedEvents.removeAll()
            sessionsByID[id] = recovered
            for event in buffered.sorted(by: { $0.seq < $1.seq }) {
                applyThreadEvent(event)
            }
            performSubscriptionMaintenance()
        } catch is CancellationError {
            return
        } catch {
            guard var failed = sessionsByID[id],
                case .subscribing(recoveryID) = failed.subscriptionState
            else { return }
            failed.subscriptionState = .unsubscribed
            failed.bufferedEvents.removeAll()
            sessionsByID[id] = failed
            if selectedThreadID == id {
                // Publish retryable failure only after the task slot is free;
                // retry() may run as soon as observers see this error.
                finishSubscriptionTask(id, operationID: operationID)
                selectedThreadLoadErrorMessage = error.localizedDescription
            }
        }
    }

    private func markInactive(_ id: String, at timestamp: Date) {
        guard var session = sessionsByID[id] else { return }
        let isProtected = session.isProtected
        session.inactiveSince = isProtected ? nil : timestamp
        if session.subscriptionState.isSubscribed {
            session.subscriptionState = isProtected ? .protected : .inactive
        }
        sessionsByID[id] = session
    }

    private func reconcileSubscriptionState(_ id: String, at timestamp: Date) {
        guard var session = sessionsByID[id],
            session.subscriptionState.isSubscribed || isSubscribing(session.subscriptionState)
        else {
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
            session.subscriptionState.isSubscribed
        else { return }

        session.subscriptionState = .unsubscribed
        session.shouldRestoreAfterReconnect = false
        // Unwatched, its content goes stale: reopening it waits for the
        // daemon's caught-up snapshot rather than showing it first.
        session.detail = nil
        session.markdownSegmentCache = ChatMarkdownSegmentCache()
        session.textLayoutStore.deactivateTextViewReuse()
        session.textLayoutStore = ChatTextLayoutStore()
        sessionsByID[id] = session
        removeEntryDetails(for: id)
        streamingTextByThreadID[id] = nil

        guard connectionState == .connected else { return }
        let previousTask = subscriptionTasks[id]?.task
        let operationID = UUID()
        let task = Task { [weak self] in
            await previousTask?.value
            guard let self, !Task.isCancelled else { return }
            try? await rpc.unsubscribeThread(id)
            finishSubscriptionTask(id, operationID: operationID)
        }
        subscriptionTasks[id] = SubscriptionTask(
            id: operationID,
            operation: .unsubscribe,
            task: task
        )
    }

    /// Subscribes again for a fresh snapshot, keeping what the chat shows
    /// until it arrives.
    private func resubscribe(_ id: String) {
        guard var session = sessionsByID[id], session.subscriptionState.isSubscribed else { return }
        session.subscriptionState = .unsubscribed
        sessionsByID[id] = session
        ensureSubscribed(id)
    }

    private func finishSubscriptionTask(_ id: String, operationID: UUID) {
        guard subscriptionTasks[id]?.id == operationID else { return }
        subscriptionTasks[id] = nil
    }

    private func removeEntryDetails(for threadID: String) {
        entryDetailsByID = entryDetailsByID.filter { $0.key.threadID != threadID }
        entryRevisions = entryRevisions.filter { $0.key.threadID != threadID }
    }

    private func scheduleMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = nil

        guard connectionState == .connected else { return }
        let timestamp = now()
        let nextExpiration = sessionsByID.values.compactMap { session -> Date? in
            guard case .inactive = session.subscriptionState,
                let inactiveSince = session.inactiveSince
            else { return nil }
            return inactiveSince.addingTimeInterval(Self.inactiveSubscriptionLifetime)
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

    // MARK: Notifications

    private func receiveNotification(method: String, data: Data) {
        do {
            switch method {
            case MaidRPCMethod.threadList:
                let notification = try decoder.decode(Notification<ThreadListItem>.self, from: data)
                receiveThreadListItem(notification.params)
            case MaidRPCMethod.threadEvent:
                let notification = try decoder.decode(Notification<ThreadEvent>.self, from: data)
                receiveThreadEvent(notification.params)
            case MaidRPCMethod.providerOptionsUpdated:
                let notification = try decoder.decode(Notification<ProviderOptionsResult>.self, from: data)
                onProviderOptionsUpdated?(notification.params)
            case MaidRPCMethod.providerOptionsInvalidated:
                let notification = try decoder.decode(Notification<ProviderOptionsInvalidated>.self, from: data)
                onProviderOptionsInvalidated?(notification.params)
            case MaidRPCMethod.providerQuestionAsked:
                let notification = try decoder.decode(Notification<ProviderQuestion>.self, from: data)
                providerQuestion = notification.params
            default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func receiveThreadEvent(_ event: ThreadEvent) {
        guard var session = sessionsByID[event.thread] else { return }
        if case .subscribing = session.subscriptionState {
            session.bufferedEvents.append(event)
            sessionsByID[event.thread] = session
        } else {
            applyThreadEvent(event)
        }
    }

    /// Replaces only server-owned thread data, preserving local subscription
    /// and presentation-cache state.
    private func replaceThreadContents(
        with snapshot: ThreadSnapshot,
        session: inout ThreadSession
    ) {
        let threadID = snapshot.thread.id
        removeEntryDetails(for: threadID)
        streamingTextByThreadID[threadID] = nil
        session.detail = ThreadDetail(snapshot)
        // The turns were replaced, not appended to.
        session.timelineProjection.invalidateAll()
    }

    #if DEBUG
        func insertSyntheticBenchmarkThread(_ detail: ThreadDetail) {
            guard detail.id.hasPrefix("synthetic-benchmark-") else { return }
            var session = ThreadSession(detail: detail)
            session.subscriptionState = .inactive
            session.inactiveSince = now()
            sessionsByID[detail.id] = session
            threads.append(detail.summary)
            noteThreadsChanged()
        }

        func applySyntheticBenchmarkEvent(_ event: ThreadEvent) {
            guard selectedThreadID == ChatSyntheticBenchmarkThread.threadID,
                event.thread == ChatSyntheticBenchmarkThread.threadID
            else { return }
            applyThreadEvent(event)
        }
    #endif

    private func applyThreadEvent(_ event: ThreadEvent) {
        let threadID = event.thread
        // Straight through the subscript: a local copy of the session would
        // defeat copy-on-write and duplicate the turns on every chunk.
        guard let result = sessionsByID[threadID]?.apply(event) else { return }
        switch result.change {
        case .none:
            return
        case .refresh:
            resubscribe(threadID)
            return
        case .removed:
            removeThread(threadID)
            return
        case .text(let turnID, let entryRef, let delta):
            if updateStreamingText(threadID: threadID, turnID: turnID, entryRef: entryRef, delta: delta) {
                return
            }
        case .turns:
            if let turn = event.turn, let entry = event.entry {
                let rowID = "\(turn.id)|\(entry.ref)"
                streamingTextByThreadID[threadID]?[rowID] = nil
                entryRevisions[EntryDetailID(threadID: threadID, rowID: rowID), default: 0] += 1
            }
            if event.turn?.turnState?.isSettled == true {
                streamingTextByThreadID[threadID] = nil
            }
        case .thread:
            if let participant = event.participant, participant.live {
                refreshProviderAfterAgentStarted(participant.instance)
            }
        }
        noteSelectedSessionChanged(threadID)
        if threadID == selectedThreadID, sessionsByID[threadID]?.detail?.summary.attention.unread == true {
            // What finished while it was open has been seen.
            markThreadRead(threadID)
        }
        if result.protectionChanged {
            reconcileSubscriptionState(threadID, at: now())
            performSubscriptionMaintenance()
        }
    }

    private func removeThread(_ threadID: String) {
        sessionsByID[threadID] = nil
        streamingTextByThreadID[threadID] = nil
        removeEntryDetails(for: threadID)
        if selectedThreadID == threadID {
            selectedThreadID = nil
            selectedThreadLoadErrorMessage = nil
            recomputeSelectedThreadTitle()
        }
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

    /// Appends streamed text to the live leaf row showing it. Returns true when
    /// the leaf took it, so nothing structural needs publishing.
    private func updateStreamingText(threadID: String, turnID: String, entryRef: String, delta: String) -> Bool {
        let rowID = "\(turnID)|\(entryRef)"
        if let streamingText = streamingTextByThreadID[threadID]?[rowID] {
            streamingText.append(delta)
            return true
        }
        guard let turn = sessionsByID[threadID]?.detail?.turns.last(where: { $0.id == turnID }),
            let entry = turn.entries.last(where: { $0.ref == entryRef }),
            entry.itemKind == .assistantMessage || entry.itemKind == .reasoning
        else { return false }
        streamingTextByThreadID[threadID, default: [:]][rowID] = ThreadStreamingText(text: entry.text ?? "")
        return false
    }

    /// The live text of a streaming row, by its row ID.
    func streamingText(threadID: String, rowID: String) -> ThreadStreamingText? {
        streamingTextByThreadID[threadID]?[rowID]
    }

    private func receiveThreadListItem(_ item: ThreadListItem) {
        if isLoadingThreadListSnapshot {
            bufferedThreadListItems.append(item)
        } else {
            applyThreadListUpdate(item)
        }
    }

    private func applyThreadListSnapshot(_ item: ThreadListItem) -> Bool {
        guard MaidThreadListKind(rawValue: item.kind) == .snapshot else {
            errorMessage = "maiD returned an invalid thread-list snapshot"
            isLoadingThreadListSnapshot = false
            bufferedThreadListItems.removeAll()
            return false
        }

        let snapshot = item.threads ?? []
        lastThreadListSequence = item.seq
        threads = snapshot
        sortThreads()
        if let selectedThreadID,
            !snapshot.contains(where: { $0.id == selectedThreadID })
        {
            removeThread(selectedThreadID)
        }
        noteThreadsChanged()
        isLoadingThreadListSnapshot = false

        let bufferedItems = bufferedThreadListItems
        bufferedThreadListItems.removeAll()
        for bufferedItem in bufferedItems.sorted(by: { $0.seq < $1.seq }) {
            applyThreadListUpdate(bufferedItem)
        }
        return true
    }

    private func applyThreadListUpdate(_ item: ThreadListItem) {
        guard item.seq > lastThreadListSequence else { return }
        lastThreadListSequence = item.seq

        switch MaidThreadListKind(rawValue: item.kind) {
        case .upsert:
            guard let thread = item.thread else { return }
            threads.removeAll { $0.id == thread.id }
            threads.append(thread)
            sortThreads()
            noteThreadsChanged()
        case .remove:
            guard let removed = item.removed else { return }
            threads.removeAll { $0.id == removed }
            removeThread(removed)
            noteThreadsChanged()
        case .snapshot, nil:
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

    #if DEBUG
        var cachedThreadIDs: Set<String> {
            Set(sessionsByID.compactMap { $0.value.detail == nil ? nil : $0.key })
        }

        func cachedThread(for id: String) -> ThreadDetail? {
            sessionsByID[id]?.detail
        }

        var subscribedThreadIDs: Set<String> {
            Set(sessionsByID.compactMap { $0.value.subscriptionState.isSubscribed ? $0.key : nil })
        }

        var inactiveSubscribedThreadIDs: Set<String> {
            Set(
                sessionsByID.compactMap {
                    if case .inactive = $0.value.subscriptionState { return $0.key }
                    return nil
                })
        }

        var protectedSubscribedThreadIDs: Set<String> {
            Set(
                sessionsByID.compactMap {
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
        case invalidEntryDetail

        var errorDescription: String? {
            switch self {
            case .invalidSnapshot:
                "maiD returned an invalid authoritative thread snapshot"
            case .invalidEntryDetail:
                "maiD returned an invalid entry"
            }
        }
    }
}

private struct EntryDetailID: Hashable {
    let threadID: String
    let rowID: String
}

private struct CachedEntryDetail {
    let entry: Entry
    let revision: Int
}
