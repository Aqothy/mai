import Foundation
import Observation

@Observable
final class ACPRegistryModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var installingIDs: Set<String> = []
    private(set) var errorMessage: String?
    /// Cached so body evaluations don't re-run the merge/sort/filter pipeline
    /// and don't depend on the store's whole installed-agents collection.
    /// Rebuilt whenever filter, registryAgents, or store.installedAgents can
    /// have changed.
    private(set) var entries: [ACPRegistryEntry] = []
    var filter: ACPRegistryFilter = .all {
        didSet { rebuildEntries() }
    }

    private let store: ThreadStore
    private var registryAgents: [ACPRegistryAgent] = []

    init(store: ThreadStore) {
        self.store = store
        rebuildEntries()
    }

    #if DEBUG
    init(store: ThreadStore, previewAgents: [ACPRegistryAgent]) {
        self.store = store
        registryAgents = previewAgents
        phase = .loaded
        rebuildEntries()
    }
    #endif

    func rebuildEntries() {
        let installedByID = Dictionary(
            uniqueKeysWithValues: store.installedAgents.map { ($0.id, $0) }
        )
        var entries = registryAgents.map { agent in
            ACPRegistryEntry(
                id: agent.id,
                name: agent.name,
                description: agent.description,
                availableVersion: agent.version,
                installedVersion: installedByID[agent.id]?.version
            )
        }
        // Installed agents the registry no longer lists stay visible so the
        // user's selection remains discoverable.
        let registryIDs = Set(registryAgents.map(\.id))
        entries += store.installedAgents
            .filter { !registryIDs.contains($0.id) }
            .map { agent in
                ACPRegistryEntry(
                    id: agent.id,
                    name: agent.name,
                    description: agent.description,
                    availableVersion: nil,
                    installedVersion: agent.version
                )
            }
        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        switch filter {
        case .all:
            self.entries = entries
        case .installed:
            self.entries = entries.filter(\.isInstalled)
        case .notInstalled:
            self.entries = entries.filter { !$0.isInstalled }
        }
    }

    var isErrorPresented: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    func load() async {
        if case .loaded = phase {} else {
            phase = .loading
        }
        do {
            try await store.refreshInstalledAgents()
            rebuildEntries()
            registryAgents = try await store.fetchRegistryAgents()
            rebuildEntries()
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            if registryAgents.isEmpty && store.installedAgents.isEmpty {
                phase = .failed(error.localizedDescription)
            } else {
                phase = .loaded
                errorMessage = error.localizedDescription
            }
        }
    }

    func install(_ entry: ACPRegistryEntry) async {
        guard !installingIDs.contains(entry.id) else { return }
        installingIDs.insert(entry.id)
        // Rebuilding in the defer covers every exit; the store mutates
        // installedAgents before a later await in installRegistryAgent can
        // throw or get cancelled.
        defer {
            installingIDs.remove(entry.id)
            rebuildEntries()
        }
        do {
            _ = try await store.installRegistryAgent(id: entry.id)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
