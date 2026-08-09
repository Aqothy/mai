import SwiftUI

struct ACPRegistryView: View {
    let store: ThreadStore

    @State private var model: ACPRegistryModel
    @State private var isCustomAgentFormPresented = false

    init(store: ThreadStore) {
        self.store = store
        _model = State(initialValue: ACPRegistryModel(store: store))
    }

    #if DEBUG
    init(store: ThreadStore, model: ACPRegistryModel) {
        self.store = store
        _model = State(initialValue: model)
    }
    #endif

    var body: some View {
        @Bindable var model = model
        List {
            ForEach(model.entries) { entry in
                ACPRegistryRow(
                    entry: entry,
                    isInstalling: model.installingIDs.contains(entry.id),
                    install: {
                        Task { await model.install(entry) }
                    }
                )
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top, spacing: 0) {
            ACPRegistryFilterPicker(filter: $model.filter)
        }
        .searchable(text: $model.searchText, prompt: "Search Agents")
        .overlay {
            ACPRegistryStatusView(model: model)
        }
        .navigationTitle("Agent Registry")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Add Custom Agent", systemImage: "plus") {
                    isCustomAgentFormPresented = true
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .modifier(ACPRegistryInstalledAgentsSync(store: store, model: model))
        .sheet(isPresented: $isCustomAgentFormPresented) {
            NavigationStack {
                CustomACPAgentForm(store: store)
            }
        }
        .alert("Agent Registry Error", isPresented: $model.isErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "An unknown error occurred.")
        }
    }
}

/// Rebuilds the cached entries when the store refreshes installed agents
/// outside the registry model (e.g. on reconnect). Lives in its own modifier
/// so only this lightweight body — not the whole registry screen — depends on
/// the installed-agents collection.
private struct ACPRegistryInstalledAgentsSync: ViewModifier {
    let store: ThreadStore
    let model: ACPRegistryModel

    func body(content: Content) -> some View {
        content
            .onChange(of: store.installedAgents.map(InstalledAgentSnapshot.init)) {
                model.rebuildEntries()
            }
    }
}

/// Only the installed-agent fields that affect registry rows.
private struct InstalledAgentSnapshot: Equatable {
    let id: String
    let name: String
    let description: String?
    let source: String
    let version: String

    init(_ agent: ACPRegistryInstalledAgent) {
        id = agent.id
        name = agent.name
        description = agent.description
        source = agent.source
        version = agent.version
    }
}

struct ACPRegistryFilterPicker: View {
    @Binding var filter: ACPRegistryFilter

    var body: some View {
        Picker("Filter", selection: $filter) {
            ForEach(ACPRegistryFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding([.horizontal, .bottom])
        .background(.bar)
    }
}

struct ACPRegistryStatusView: View {
    let model: ACPRegistryModel

    var body: some View {
        switch model.phase {
        case .loading:
            if model.entries.isEmpty {
                ProgressView("Loading Agents…")
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("Registry Unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Retry", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
            }
        case .loaded:
            if model.entries.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "puzzlepiece.extension"
                )
            }
        }
    }

    private var emptyTitle: LocalizedStringResource {
        if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No Matching Agents"
        }
        switch model.filter {
        case .installed: return "No Installed Agents"
        case .notInstalled: return "All Agents Installed"
        case .all: return "No Agents Available"
        }
    }
}

#if DEBUG
#Preview("Agent Registry") {
    let store = ThreadStore(
        previewThreads: [],
        installedAgents: [
            ACPRegistryInstalledAgent(
                args: nil,
                description: nil,
                icon: nil,
                id: "claude-code",
                installedAt: .now,
                instanceID: "registry-claude-code",
                name: "Claude Code",
                package: "claude-code-acp@1.0.0",
                source: "registry",
                version: "1.0.0"
            )
        ]
    )
    NavigationStack {
        ACPRegistryView(
            store: store,
            model: ACPRegistryModel(
                store: store,
                previewAgents: [
                    ACPRegistryAgent(
                        args: nil,
                        description: "Use Claude Code from any ACP client.",
                        icon: nil,
                        id: "claude-code",
                        instanceID: "registry-claude-code",
                        name: "Claude Code",
                        package: "claude-code-acp@1.2.0",
                        version: "1.2.0"
                    ),
                    ACPRegistryAgent(
                        args: nil,
                        description: "OpenAI Codex agent.",
                        icon: nil,
                        id: "codex",
                        instanceID: "registry-codex",
                        name: "Codex",
                        package: "codex-acp@0.4.1",
                        version: "0.4.1"
                    ),
                ]
            )
        )
    }
}
#endif
