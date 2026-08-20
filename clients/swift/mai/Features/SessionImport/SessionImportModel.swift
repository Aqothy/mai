import Foundation
import Observation

@Observable
final class SessionImportModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var entries: [SessionImportEntry] = []
    private(set) var capabilities: SessionImportCapabilities = .unavailable
    private(set) var importingSessionIDs: Set<String> = []
    private(set) var maintenanceBySessionID: [String: SessionMaintenanceAction] = [:]
    private(set) var closedSessionIDs: Set<String> = []
    private(set) var errorMessage: String?
    var selectedAgentID: String?

    private let store: ThreadStore
    /// The agent the current `entries` were listed for, so switching agents
    /// clears the stale list while a refresh of the same agent keeps it.
    private var loadedAgentID: String?

    init(store: ThreadStore) {
        self.store = store
    }

    #if DEBUG
    init(store: ThreadStore, previewSessions: [SessionSummary]) {
        self.store = store
        entries = previewSessions.map(SessionImportEntry.init)
        capabilities = SessionImportCapabilities(
            canImport: true,
            canClose: true,
            canDelete: true
        )
        phase = .loaded
        loadedAgentID = store.availableProviders.first?.id
    }
    #endif

    var agentChoices: [ProviderChoice] {
        store.availableProviders
    }

    /// The agent sessions are listed for: the explicit selection, falling
    /// back to the first available choice.
    var effectiveAgentID: String? {
        selectedAgentID ?? agentChoices.first?.id
    }

    /// Binding projection for the agent picker: reads the effective agent and
    /// routes writes through selectedAgentID.
    var agentSelection: String? {
        get { effectiveAgentID }
        set { selectedAgentID = newValue }
    }

    var isErrorPresented: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    func load() async {
        guard let agentID = effectiveAgentID else {
            entries = []
            capabilities = .unavailable
            closedSessionIDs = []
            loadedAgentID = nil
            phase = .loaded
            return
        }
        if agentID != loadedAgentID {
            entries = []
            capabilities = .unavailable
            closedSessionIDs = []
        }
        phase = .loading
        do {
            let listed = try await store.fetchProviderSessions(agentID: agentID)
            guard effectiveAgentID == agentID else { return }
            entries = listed.map(SessionImportEntry.init)
            capabilities = SessionImportCapabilities(
                canImport: store.providerSupportsSessionImport(agentID),
                canClose: store.providerSupportsSessionClose(agentID),
                canDelete: store.providerSupportsSessionDelete(agentID)
            )
            closedSessionIDs = []
            loadedAgentID = agentID
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard effectiveAgentID == agentID else { return }
            // A failed refresh keeps the previously loaded list visible and
            // reports through the alert; the failure overlay is for an empty
            // screen only.
            if entries.isEmpty {
                phase = .failed(error.localizedDescription)
            } else {
                phase = .loaded
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Imports a session and returns the resulting thread id, or nil when the
    /// import fails; failures are surfaced through `errorMessage`.
    func importSession(_ entry: SessionImportEntry) async -> String? {
        guard let agentID = effectiveAgentID,
              capabilities.canImport,
              !importingSessionIDs.contains(entry.id) else { return nil }
        importingSessionIDs.insert(entry.id)
        defer { importingSessionIDs.remove(entry.id) }
        do {
            return try await store.importProviderSession(agentID: agentID, session: entry.summary)
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func closeSession(_ entry: SessionImportEntry) async {
        guard capabilities.canClose, !closedSessionIDs.contains(entry.id) else { return }
        await maintainSession(entry, action: .close)
    }

    func deleteSession(_ entry: SessionImportEntry) async {
        guard capabilities.canDelete else { return }
        await maintainSession(entry, action: .delete)
    }

    private func maintainSession(
        _ entry: SessionImportEntry,
        action: SessionMaintenanceAction
    ) async {
        guard let agentID = effectiveAgentID,
              maintenanceBySessionID[entry.id] == nil,
              !importingSessionIDs.contains(entry.id)
        else { return }

        maintenanceBySessionID[entry.id] = action
        defer { maintenanceBySessionID[entry.id] = nil }
        do {
            switch action {
            case .close:
                try await store.closeProviderSession(agentID: agentID, sessionID: entry.id)
                guard effectiveAgentID == agentID else { return }
                closedSessionIDs.insert(entry.id)
            case .delete:
                try await store.deleteProviderSession(agentID: agentID, sessionID: entry.id)
                guard effectiveAgentID == agentID else { return }
                entries.removeAll { $0.id == entry.id }
                closedSessionIDs.remove(entry.id)
            }
        } catch is CancellationError {
            return
        } catch {
            guard effectiveAgentID == agentID else { return }
            errorMessage = error.localizedDescription
        }
    }
}
