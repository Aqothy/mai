import SwiftUI

struct SessionImportView: View {
    let store: ThreadStore
    let openThread: (String) -> Void

    @State private var model: SessionImportModel

    init(store: ThreadStore, openThread: @escaping (String) -> Void) {
        self.store = store
        self.openThread = openThread
        _model = State(initialValue: SessionImportModel(store: store))
    }

    #if DEBUG
    init(store: ThreadStore, model: SessionImportModel, openThread: @escaping (String) -> Void) {
        self.store = store
        self.openThread = openThread
        _model = State(initialValue: model)
    }
    #endif

    var body: some View {
        @Bindable var model = model
        List {
            ForEach(model.entries) { entry in
                SessionImportRow(
                    entry: entry,
                    isImporting: model.importingSessionIDs.contains(entry.id),
                    importSession: {
                        Task {
                            if let threadID = await model.importSession(entry) {
                                openThread(threadID)
                            }
                        }
                    }
                )
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top, spacing: 0) {
            SessionImportAgentPicker(
                choices: model.agentChoices,
                selection: $model.agentSelection
            )
        }
        .overlay {
            SessionImportStatusView(model: model)
        }
        .navigationTitle("Import Session")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
            }
        }
        .task(id: model.effectiveAgentID) {
            await model.load()
        }
        .refreshable { await model.load() }
        .alert("Session Import Error", isPresented: $model.isErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "An unknown error occurred.")
        }
    }
}

struct SessionImportAgentPicker: View {
    let choices: [SessionImportAgentChoice]
    @Binding var selection: String?

    var body: some View {
        HStack {
            Text("Agent")
            Spacer()
            Picker("Agent", selection: $selection) {
                ForEach(choices) { choice in
                    Text(choice.name).tag(Optional(choice.id))
                }
            }
            .labelsHidden()
        }
        .padding([.horizontal, .bottom])
        .background(.bar)
    }
}

struct SessionImportStatusView: View {
    let model: SessionImportModel

    var body: some View {
        if model.agentChoices.isEmpty {
            ContentUnavailableView(
                "No Agents Available",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Configure an agent before importing sessions.")
            )
        } else {
            switch model.phase {
            case .loading:
                if model.entries.isEmpty {
                    ProgressView("Loading Sessions…")
                }
            case let .failed(message):
                ContentUnavailableView {
                    Label("Sessions Unavailable", systemImage: "exclamationmark.triangle")
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
                        "No Sessions Found",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("This agent has no sessions to import.")
                    )
                }
            }
        }
    }
}

#if DEBUG
#Preview("Import Session") {
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
        SessionImportView(
            store: store,
            model: SessionImportModel(
                store: store,
                previewSessions: [
                    SessionSummary(
                        cwd: "/Users/me/Code/maiD",
                        sessionID: "sess-1",
                        title: "Fix reconnect loop",
                        updatedAt: "2026-08-01T10:15:30Z"
                    ),
                    SessionSummary(
                        cwd: "/Users/me/Code/side-project",
                        sessionID: "sess-2",
                        title: nil,
                        updatedAt: nil
                    ),
                ]
            ),
            openThread: { _ in }
        )
    }
}
#endif
