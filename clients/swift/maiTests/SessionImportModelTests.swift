import Foundation
import Testing
@testable import mai

struct SessionImportModelTests {
    @Test
    func listsSessionsForDefaultAgent() async {
        let rpc = SessionImportMockRPCClient()
        rpc.providers = [makeSessionImportProvider(instanceID: "claude", name: "Claude")]
        rpc.sessions = [makeSessionSummary("sess-1", title: "Fix crash")]
        let model = SessionImportModel(store: await makeStartedStore(rpc))

        #expect(model.effectiveAgentID == "claude")
        await model.load()

        #expect(model.phase == .loaded)
        #expect(model.entries.map(\.id) == ["sess-1"])
        #expect(rpc.listInputs.map(\.instanceID) == ["claude"])
    }

    @Test
    func switchingAgentsClearsStaleSessions() async {
        let rpc = SessionImportMockRPCClient()
        rpc.providers = [
            makeSessionImportProvider(instanceID: "claude", name: "Claude"),
            makeSessionImportProvider(instanceID: "codex", name: "Codex"),
        ]
        rpc.sessions = [makeSessionSummary("sess-1")]
        let model = SessionImportModel(store: await makeStartedStore(rpc))
        await model.load()
        #expect(!model.entries.isEmpty)

        rpc.listSessionsError = RPCError(code: nil, message: "boom", data: nil)
        model.selectedAgentID = "codex"
        await model.load()

        #expect(model.entries.isEmpty)
        #expect(model.phase == .failed("boom"))
    }

    @Test
    func refreshFailureKeepsLoadedSessions() async {
        let rpc = SessionImportMockRPCClient()
        rpc.providers = [makeSessionImportProvider(instanceID: "claude", name: "Claude")]
        rpc.sessions = [makeSessionSummary("sess-1")]
        let model = SessionImportModel(store: await makeStartedStore(rpc))
        await model.load()

        rpc.listSessionsError = RPCError(code: nil, message: "boom", data: nil)
        await model.load()

        #expect(model.phase == .loaded)
        #expect(model.entries.map(\.id) == ["sess-1"])
        #expect(model.errorMessage == "boom")
    }

    @Test
    func loadFailureShowsFailedPhase() async {
        let rpc = SessionImportMockRPCClient()
        rpc.providers = [makeSessionImportProvider(instanceID: "claude", name: "Claude")]
        rpc.listSessionsError = RPCError(code: nil, message: "listing not supported", data: nil)
        let model = SessionImportModel(store: await makeStartedStore(rpc))

        await model.load()

        #expect(model.phase == .failed("listing not supported"))
    }

    @Test
    func doesNotRequestSessionsWhenProviderCannotListThem() async {
        let rpc = SessionImportMockRPCClient()
        rpc.providers = [
            makeSessionImportProvider(instanceID: "claude", name: "Claude", canListSessions: false)
        ]
        let model = SessionImportModel(store: await makeStartedStore(rpc))

        await model.load()

        #expect(model.phase == .failed("This agent does not support listing sessions"))
        #expect(rpc.listInputs.isEmpty)
    }

    @Test
    func listsMaintenanceOnlySessionsWithoutOfferingImport() async {
        let rpc = SessionImportMockRPCClient()
        rpc.providers = [
            makeSessionImportProvider(
                instanceID: "claude",
                name: "Claude",
                canImportSessions: false,
                canCloseSessions: true
            )
        ]
        rpc.sessions = [makeSessionSummary("sess-1")]
        let model = SessionImportModel(store: await makeStartedStore(rpc))

        await model.load()
        let importedThreadID = await model.importSession(model.entries[0])

        #expect(model.entries.map(\.id) == ["sess-1"])
        #expect(model.capabilities == SessionImportCapabilities(
            canImport: false,
            canClose: true,
            canDelete: false
        ))
        #expect(importedThreadID == nil)
        #expect(rpc.importInputs.isEmpty)
    }

    @Test
    func loadWithoutAgentsShowsEmptyState() async {
        let rpc = SessionImportMockRPCClient()
        let model = SessionImportModel(store: await makeStartedStore(rpc))

        #expect(model.effectiveAgentID == nil)
        await model.load()

        #expect(model.phase == .loaded)
        #expect(model.entries.isEmpty)
        #expect(rpc.listInputs.isEmpty)
    }

    @Test
    func importReturnsThreadID() async {
        let rpc = SessionImportMockRPCClient()
        rpc.providers = [makeSessionImportProvider(instanceID: "claude", name: "Claude")]
        let session = makeSessionSummary("sess-1")
        rpc.sessions = [session]
        let model = SessionImportModel(store: await makeStartedStore(rpc))
        await model.load()

        let threadID = await model.importSession(SessionImportEntry(summary: session))

        #expect(threadID == "thread-sess-1")
        #expect(model.importingSessionIDs.isEmpty)
        #expect(model.errorMessage == nil)
        #expect(rpc.importInputs.map(\.instanceID) == ["claude"])
        #expect(rpc.importInputs.map(\.session.sessionID) == ["sess-1"])
    }

    @Test
    func importFailureSurfacesErrorMessage() async {
        let rpc = SessionImportMockRPCClient()
        rpc.providers = [makeSessionImportProvider(instanceID: "claude", name: "Claude")]
        rpc.importError = RPCError(code: nil, message: "import failed", data: nil)
        let model = SessionImportModel(store: await makeStartedStore(rpc))
        await model.load()

        let threadID = await model.importSession(
            SessionImportEntry(summary: makeSessionSummary("sess-1"))
        )

        #expect(threadID == nil)
        #expect(model.errorMessage == "import failed")
        #expect(model.importingSessionIDs.isEmpty)
    }

    @Test
    func closesSupportedSessionAndKeepsItImportable() async {
        let rpc = SessionImportMockRPCClient()
        rpc.providers = [
            makeSessionImportProvider(
                instanceID: "claude",
                name: "Claude",
                canCloseSessions: true
            )
        ]
        rpc.sessions = [makeSessionSummary("sess-1")]
        let model = SessionImportModel(store: await makeStartedStore(rpc))
        await model.load()

        await model.closeSession(model.entries[0])

        #expect(rpc.closeInputs.map(\.sessionID) == ["sess-1"])
        #expect(model.entries.map(\.id) == ["sess-1"])
        #expect(model.closedSessionIDs == ["sess-1"])
        #expect(model.maintenanceBySessionID.isEmpty)
    }

    @Test
    func deletesSupportedSessionFromList() async {
        let rpc = SessionImportMockRPCClient()
        rpc.providers = [
            makeSessionImportProvider(
                instanceID: "claude",
                name: "Claude",
                canDeleteSessions: true
            )
        ]
        rpc.sessions = [makeSessionSummary("sess-1")]
        let model = SessionImportModel(store: await makeStartedStore(rpc))
        await model.load()

        await model.deleteSession(model.entries[0])

        #expect(rpc.deleteInputs.map(\.sessionID) == ["sess-1"])
        #expect(model.entries.isEmpty)
        #expect(model.maintenanceBySessionID.isEmpty)
    }

    @Test
    func entryPreparesTitleAndTimestamp() {
        func makeEntry(title: String? = nil, updatedAt: String? = nil) -> SessionImportEntry {
            SessionImportEntry(summary: makeSessionSummary("sess-1", title: title, updatedAt: updatedAt))
        }

        #expect(makeEntry(title: "Fix crash").title == "Fix crash")
        #expect(makeEntry(title: "  ").title == "sess-1")
        #expect(makeEntry().title == "sess-1")
        #expect(makeEntry(updatedAt: "2026-08-01T10:15:30Z").updatedAt != nil)
        #expect(makeEntry(updatedAt: "2026-08-01T10:15:30.123456789Z").updatedAt != nil)
        #expect(makeEntry(updatedAt: "yesterday").updatedAt == nil)
        #expect(makeEntry().updatedAt == nil)
    }

    private func makeStartedStore(_ rpc: SessionImportMockRPCClient) async -> ThreadStore {
        let store = ThreadStore(rpc: rpc)
        await store.start()
        return store
    }
}

private func makeSessionImportProvider(
    instanceID: String,
    name: String,
    canListSessions: Bool = true,
    canImportSessions: Bool = true,
    canCloseSessions: Bool = false,
    canDeleteSessions: Bool = false
) -> InstanceInfo {
    InstanceInfo(
        auth: Auth(methods: nil, status: "authenticated"),
        capabilities: Capabilities(
            additionalDirectories: nil,
            auth: nil,
            configOptions: nil,
            fork: nil,
            loadReplay: canImportSessions,
            logout: nil,
            mcp: nil,
            modelSwitch: nil,
            promptContent: nil,
            resume: false,
            sessionClose: canCloseSessions,
            sessionDelete: canDeleteSessions,
            sessionList: canListSessions,
            skills: nil
        ),
        driver: "mock",
        initializedAt: .now,
        instanceID: instanceID,
        name: name,
        pid: nil,
        startedAt: .now,
        status: "initialized"
    )
}

private func makeSessionSummary(
    _ sessionID: String,
    title: String? = nil,
    updatedAt: String? = nil
) -> SessionSummary {
    SessionSummary(
        additionalDirectories: nil,
        cwd: "/tmp/project",
        sessionID: sessionID,
        title: title,
        updatedAt: updatedAt
    )
}

private final class SessionImportMockRPCClient: ThreadRPCClient {
    var onNotification: ((String, Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    var providers: [InstanceInfo] = []
    var sessions: [SessionSummary] = []
    var listSessionsError: RPCError?
    var importError: RPCError?
    private(set) var listInputs: [ProviderListSessionsParams] = []
    private(set) var importInputs: [ProviderImportSessionParams] = []
    private(set) var closeInputs: [ProviderSessionParams] = []
    private(set) var deleteInputs: [ProviderSessionParams] = []

    func connect() {}
    func disconnect() {}

    func subscribeThreadList() async throws -> ThreadListStreamItem {
        ThreadListStreamItem(
            kind: "snapshot",
            sequence: nil,
            snapshot: ThreadListSnapshot(
                snapshotSequence: 0,
                threads: [],
                updatedAt: .now
            ),
            thread: nil
        )
    }

    func subscribeThread(_ input: SubscribeThreadInput) async throws -> ThreadStreamItem {
        throw RPCError(code: nil, message: "Thread subscriptions are unavailable", data: nil)
    }

    func unsubscribeThread(_ input: SubscribeThreadInput) async throws {}

    func listProviders() async throws -> [InstanceInfo] { providers }

    func listProviderSessions(_ input: ProviderListSessionsParams) async throws -> [SessionSummary] {
        listInputs.append(input)
        if let listSessionsError { throw listSessionsError }
        return sessions
    }

    func importProviderSession(_ input: ProviderImportSessionParams) async throws -> ProviderImportSessionResult {
        importInputs.append(input)
        if let importError { throw importError }
        return ProviderImportSessionResult(
            imported: true,
            threadID: "thread-\(input.session.sessionID)"
        )
    }

    func closeProviderSession(_ input: ProviderSessionParams) async throws {
        closeInputs.append(input)
    }

    func deleteProviderSession(_ input: ProviderSessionParams) async throws {
        deleteInputs.append(input)
    }
}
