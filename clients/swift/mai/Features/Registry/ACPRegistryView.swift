import SwiftUI

struct ACPRegistryView: View {
    let store: ThreadStore

    @State private var model: ACPRegistryModel
    @State private var isCustomAgentFormPresented = false
    @State private var agentBeingEdited: ACPRegistryAgent?
    @State private var agentToRemove: ACPRegistryEntry?
    @State private var areProviderAccountsPresented = false

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
                    isBusy: model.busyIDs.contains(entry.id),
                    install: {
                        Task { await model.install(entry) }
                    },
                    edit: {
                        agentBeingEdited = store.installedAgents.first { $0.id == entry.id }
                    },
                    remove: { agentToRemove = entry }
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
        .inlineNavigationBarTitle()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Provider Accounts", systemImage: "person.crop.circle") {
                    areProviderAccountsPresented = true
                }
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
        .modifier(ACPRegistryListSync(store: store, model: model))
        .sheet(isPresented: $isCustomAgentFormPresented) {
            NavigationStack {
                CustomACPAgentForm(store: store)
            }
        }
        .sheet(item: $agentBeingEdited) { agent in
            NavigationStack {
                CustomACPAgentForm(store: store, editing: agent)
            }
        }
        .confirmationDialog(
            "Remove \(agentToRemove?.name ?? "")?",
            isPresented: Binding(
                get: { agentToRemove != nil },
                set: { if !$0 { agentToRemove = nil } }
            ),
            titleVisibility: .visible,
            presenting: agentToRemove
        ) { entry in
            Button("Remove", role: .destructive) {
                Task { await model.remove(entry) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(
                entry.source == .custom
                    ? "Its chats stay in your list but can’t continue."
                    : "Everything maiD downloaded for it is deleted. Its chats stay in your list but can’t continue until you install it again."
            )
        }
        .sheet(isPresented: $areProviderAccountsPresented) {
            NavigationStack {
                ProviderAccountsView(store: store)
            }
        }
        .alert("Agent Registry Error", isPresented: $model.isErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "An unknown error occurred.")
        }
    }
}

extension ACPRegistryAgent: Identifiable {}

/// Rebuilds the cached entries whenever the daemon's list changes, from any
/// device. Lives in its own modifier so only this lightweight body — not the
/// whole registry screen — depends on the list.
private struct ACPRegistryListSync: ViewModifier {
    let store: ThreadStore
    let model: ACPRegistryModel

    func body(content: Content) -> some View {
        content
            .onChange(of: store.registryListRevision) {
                model.rebuildEntries()
            }
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
        // Reads poorly stretched across a full iPad or Mac sheet width.
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
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
        case .failed(let message):
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
                .preview(
                    id: "claude-code", name: "Claude Code", description: "Use Claude Code from any ACP client.",
                    installedVersion: "1.0.0", availableVersion: "1.2.0",
                    availableReleasedAt: .now.addingTimeInterval(-3 * 86400)
                ),
                .preview(
                    id: "codex", name: "Codex", state: .installing, description: "OpenAI Codex agent.",
                    availableVersion: "0.4.1"
                ),
                .preview(
                    id: "goose", name: "Goose", state: .failed, description: "An open source agent.",
                    availableVersion: "1.0.0", error: "npm install failed: EACCES: permission denied"
                ),
                .preview(
                    id: "kimi", name: "Kimi", state: .notInstalled, description: "Only for another platform.",
                    availableVersion: "1.0.0", blocker: .platform
                ),
                .preview(id: "my-codex", name: "My Codex", source: .custom),
            ]
        )
        NavigationStack {
            ACPRegistryView(store: store, model: ACPRegistryModel(previewStore: store))
        }
    }
#endif
