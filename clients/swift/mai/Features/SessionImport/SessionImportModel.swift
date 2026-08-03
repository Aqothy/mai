import Foundation
import Observation

/// One agent the user can import sessions from: a configured native provider
/// or an installed/running ACP agent.
struct SessionImportAgentChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

@Observable
final class SessionImportModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var entries: [SessionImportEntry] = []
    private(set) var importingSessionIDs: Set<String> = []
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
        phase = .loaded
        loadedAgentID = store.acpAgentChoices.first?.id
    }
    #endif

    var agentChoices: [SessionImportAgentChoice] {
        store.nativeProviders.map {
            SessionImportAgentChoice(id: $0.instanceID, name: $0.name)
        } + store.acpAgentChoices.map {
            SessionImportAgentChoice(id: $0.id, name: $0.name)
        }
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
            loadedAgentID = nil
            phase = .loaded
            return
        }
        if agentID != loadedAgentID {
            entries = []
        }
        phase = .loading
        do {
            let listed = try await store.fetchProviderSessions(agentID: agentID)
            guard effectiveAgentID == agentID else { return }
            entries = listed.map(SessionImportEntry.init)
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
}
