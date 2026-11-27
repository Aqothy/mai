import Foundation
import Observation

@Observable
final class ACPRegistryModel {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    /// Agents a call to the daemon is on its way for. The daemon's list says
    /// what it is doing with them.
    private(set) var busyIDs: Set<String> = []
    private(set) var errorMessage: String?
    /// Cached so body evaluations don't re-run the filter pipeline and don't
    /// depend on the store's whole agent list.
    /// Rebuilt whenever the filter, search text or the daemon's list changes.
    private(set) var entries: [ACPRegistryEntry] = []
    var filter: ACPRegistryFilter = .all {
        didSet { rebuildEntries() }
    }
    var searchText = "" {
        didSet { rebuildEntries() }
    }

    private let store: ThreadStore
    #if DEBUG
        private var usesPreviewAgents = false
    #endif

    init(store: ThreadStore) {
        self.store = store
        rebuildEntries()
    }

    #if DEBUG
    init(previewStore store: ThreadStore) {
        self.store = store
        usesPreviewAgents = true
        phase = .loaded
        rebuildEntries()
    }
    #endif

    func rebuildEntries() {
        var entries = store.registryAgents.map(ACPRegistryEntry.init)
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
        #if DEBUG
            guard !usesPreviewAgents else { return }
        #endif
        if phase != .loaded {
            phase = .loading
        }
        do {
            try await store.refreshRegistry()
            rebuildEntries()
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            if store.registryAgents.isEmpty {
                phase = .failed(error.localizedDescription)
            } else {
                phase = .loaded
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Asks the daemon to install, update or retry. The row shows the rest
    /// through the daemon's list.
    func install(_ entry: ACPRegistryEntry) async {
        guard busyIDs.insert(entry.id).inserted else { return }
        defer { busyIDs.remove(entry.id) }
        do {
            try await store.installRegistryAgent(id: entry.id)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ entry: ACPRegistryEntry) async {
        guard busyIDs.insert(entry.id).inserted else { return }
        defer { busyIDs.remove(entry.id) }
        do {
            try await store.removeInstalledAgent(id: entry.id)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
