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
    /// Rebuilt whenever the filter, search text, registry agents, or installed
    /// agents change.
    private(set) var entries: [ACPRegistryEntry] = []
    var filter: ACPRegistryFilter = .all {
        didSet { rebuildEntries() }
    }
    var searchText = "" {
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
        let customIDs = Set(store.installedAgents.lazy.compactMap { agent in
            ACPRegistryEntry.Source(rawValue: agent.source) == .custom ? agent.id : nil
        })
        var entries = registryAgents.filter { !customIDs.contains($0.id) }.map { agent in
            ACPRegistryEntry(
                id: agent.id,
                name: agent.name,
                description: agent.description,
                source: .registry,
                availableVersion: agent.version,
                installedVersion: installedByID[agent.id]?.version
            )
        }
        // Custom definitions take precedence over same-ID registry entries.
        // Other installed agents stay visible if the registry no longer lists them.
        let registryIDs = Set(registryAgents.map(\.id))
        entries += store.installedAgents
            .filter { customIDs.contains($0.id) || !registryIDs.contains($0.id) }
            .map { agent in
                let source = ACPRegistryEntry.Source(rawValue: agent.source) ?? .registry
                return ACPRegistryEntry(
                    id: agent.id,
                    name: agent.name,
                    description: agent.description,
                    source: source,
                    availableVersion: nil,
                    installedVersion: source == .custom ? nil : agent.version
                )
            }
        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        switch filter {
        case .all:
            break
        case .installed:
            entries = entries.filter(\.isInstalled)
        case .notInstalled:
            entries = entries.filter { !$0.isInstalled }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            entries = entries.filter { entry in
                entry.name.localizedStandardContains(query)
                    || entry.id.localizedStandardContains(query)
                    || entry.description?.localizedStandardContains(query) == true
                    || entry.versionLabel.localizedStandardContains(query)
            }
        }
        self.entries = entries
    }

    var isErrorPresented: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    func load() async {
        if phase != .loaded {
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
