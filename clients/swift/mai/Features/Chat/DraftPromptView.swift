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
                Image(systemName: "sparkles")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("What would you like to build?")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityHeading(.h1)

                Text("Choose a provider and describe your task.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if model.connectionState != .connected {
                    Label("Waiting for maiD…", systemImage: "network")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !model.hasProviderChoices {
                    Label("No providers available", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !model.hasWorkingDirectory {
                    Label(
                        "Choose a working directory", systemImage: "folder.badge.questionmark"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .task {
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
        .alert("Working Directory", isPresented: $model.isEnteringDirectory) {
            TextField("/path/to/project", text: $model.directoryInput)
            Button("Done") {
                model.commitDirectoryInput()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter the path mai should use for this chat.")
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

    var body: some View {
        Menu {
            ForEach(model.providerGroups) { group in
                Button {
                    model.selectProviderGroup(group)
                } label: {
                    if model.selectedProviderGroup?.id == group.id {
                        Label(group.name, systemImage: "checkmark")
                    } else {
                        Text(group.name)
                    }
                }
            }
        } label: {
            Label(model.selectedProviderGroup?.name ?? "Provider", systemImage: "server.rack")
                .lineLimit(1)
        }
        .disabled(model.isSending || !model.hasProviderChoices)
        .accessibilityLabel("Provider")

        if model.selectedProviderGroupChoices.count > 1 {
            Menu {
                ForEach(model.selectedProviderGroupChoices) { provider in
                    Button {
                        model.selectProvider(provider)
                    } label: {
                        if model.selectedProviderChoiceID == provider.id {
                            Label(provider.name, systemImage: "checkmark")
                        } else {
                            Text(provider.name)
                        }
                    }
                }
            } label: {
                Label(
                    model.selectedProviderOptionLabel,
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                .lineLimit(1)
            }
            .disabled(model.isSending)
            .accessibilityLabel("Provider option")
        }

        Menu {
            ForEach(model.recentWorkingDirectories, id: \.self) { directory in
                Button(directory) {
                    model.workingDirectory = directory
                }
            }

            if !model.recentWorkingDirectories.isEmpty {
                Divider()
            }

            Button("Enter a path…") {
                model.beginEnteringDirectory()
            }
        } label: {
            Label(model.directoryLabel, systemImage: "folder")
                .lineLimit(1)
        }
        .disabled(model.isSending)
        .accessibilityLabel("Working directory")
    }
}

struct DraftProviderChoice: Identifiable {
    let id: String
    let name: String
    let providerID: String
    let acpAgentID: String?
    let groupID: String
    let groupName: String
}

struct DraftProviderGroup: Identifiable {
    let id: String
    let name: String
    let choices: [DraftProviderChoice]
}

#if DEBUG
    #Preview("Draft Prompt") {
        DraftPromptView(
            model: DraftPromptModel(
                store: ThreadStore(
                    previewThreads: PreviewData.threads,
                    registryAgents: [
                        ACPRegistryAgent(
                            args: nil,
                            description: nil,
                            icon: nil,
                            id: "claude-code",
                            instanceID: "claude-code",
                            name: "Claude",
                            package: "claude-code-acp",
                            version: nil
                        ),
                        ACPRegistryAgent(
                            args: nil,
                            description: nil,
                            icon: nil,
                            id: "codex",
                            instanceID: "codex",
                            name: "Codex",
                            package: "codex-acp",
                            version: nil
                        ),
                    ]
                ),
                draftStore: ThreadDraftStore()
            )
        )
    }
#endif
