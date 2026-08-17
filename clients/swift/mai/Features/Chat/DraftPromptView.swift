import SwiftUI

struct DraftPromptView: View {
    let model: DraftPromptModel

    var body: some View {
        @Bindable var model = model

        ZStack {
            // empty scroll view to dismiss keyboard without scrolling content
            // view in draft
            ScrollView {
            }
            .scrollDismissesKeyboard(.interactively)

            VStack {
                if model.hasWorkingDirectory {
                    (Text("What should we build in ")
                        + Text(model.directoryLabel).underline()
                        + Text("?"))
                        .font(.largeTitle)
                        .multilineTextAlignment(.center)
                        .accessibilityHeading(.h1)
                } else {
                    Text("Choose a project folder to start")
                        .font(.largeTitle)
                        .multilineTextAlignment(.center)
                        .accessibilityHeading(.h1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .task {
            model.activate()
            model.ensureLocalDraft()
        }
        .task(id: model.catalogSelectionKey) {
            model.configureInitialSelection()
        }
        .task(id: model.optionsSelectionKey) {
            await model.loadOptions()
        }
        .alert(model.errorTitle, isPresented: $model.isErrorPresented) {
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "An unknown error occurred.")
        }
    }
}

struct DraftComposerControlsView: View {
    let model: DraftPromptModel

    @State private var isOptionsPresented = false

    var body: some View {
        Group {
            switch model.optionsPhase {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(model.optionsLoadingLabel)
            case .failed:
                Button("Retry options", systemImage: "exclamationmark.triangle") {
                    model.retryOptions()
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.orange)
                .accessibilityLabel("Retry provider options")
            case .live where !model.configOptions.isEmpty:
                ComposerOptionsButton(
                    summary: selectionSummary,
                    isPresented: $isOptionsPresented,
                    isDisabled: model.isSending
                ) {
                    ComposerOptionsSheet(
                        options: model.configOptions,
                        isOptionDisabled: { _ in model.configControlsAreDisabled },
                        setValue: { option, value in
                            model.updateConfig(option.id, value: value)
                        }
                    )
                }
            case .unavailable, .live:
                EmptyView()
            }
        }
    }

    private var selectionSummary: String {
        model.configOptions.selectionSummary ?? model.providerLabel
    }
}

struct DraftSessionControlsView: View {
    let model: DraftPromptModel

    @State private var isProviderSelectionPresented = false
    @State private var isFolderSelectionPresented = false

    var body: some View {
        Button {
            isProviderSelectionPresented = true
        } label: {
            Label(model.providerLabel, systemImage: "server.rack")
                .lineLimit(1)
        }
        .disabled(model.isSending || !model.hasProviderChoices)
        .accessibilityLabel("Provider")
        .sheet(isPresented: $isProviderSelectionPresented) {
            SearchableSelectionSheet(
                title: "Provider",
                choices: model.providerChoices.map { provider in
                    SearchableSelectionChoice(
                        id: provider.id,
                        title: provider.name,
                        subtitle: nil,
                        systemImage: "server.rack"
                    )
                },
                selectedID: model.selectedProviderID,
                emptyTitle: "No Providers",
                onSelect: { providerID in
                    guard let providerID else { return }
                    model.selectProvider(id: providerID)
                }
            )
        }

        Button {
            isFolderSelectionPresented = true
        } label: {
            Label(model.directoryLabel, systemImage: "folder")
                .lineLimit(1)
        }
        .disabled(model.isSending)
        .accessibilityLabel("Working directory")
        .sheet(isPresented: $isFolderSelectionPresented) {
            FolderSelectionSheet(
                store: model.store,
                projectFolders: model.projectFolders,
                title: "Project Folder",
                selectedFolder: model.workingDirectory,
                onSelectExisting: model.selectWorkingDirectory,
                onSelectBrowsed: { directory, parentDirectory in
                    model.addProjectFolder(
                        directory,
                        parentDirectory: parentDirectory
                    )
                }
            )
        }
    }
}

#if DEBUG
    #Preview("Draft Prompt") {
        DraftPromptView(
            model: DraftPromptModel(
                store: ThreadStore(
                    previewThreads: PreviewData.threads,
                    installedAgents: [
                        ACPRegistryInstalledAgent(
                            args: nil,
                            description: nil,
                            icon: nil,
                            id: "claude-code",
                            installedAt: .now,
                            instanceID: "claude-code",
                            name: "Claude",
                            package: "claude-code-acp@1.0.0",
                            source: "registry",
                            version: "1.0.0"
                        ),
                        ACPRegistryInstalledAgent(
                            args: nil,
                            description: nil,
                            icon: nil,
                            id: "codex",
                            installedAt: .now,
                            instanceID: "codex",
                            name: "Codex",
                            package: "codex-acp@1.0.0",
                            source: "registry",
                            version: "1.0.0"
                        ),
                    ]
                ),
                draftStore: ThreadDraftStore()
            )
        )
    }
#endif
