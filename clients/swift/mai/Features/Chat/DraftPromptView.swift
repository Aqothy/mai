import SwiftUI

struct DraftPromptView: View {
    @State private var model: DraftPromptModel

    init(store: ThreadStore, draftStore: ThreadDraftStore) {
        _model = State(initialValue: DraftPromptModel(store: store, draftStore: draftStore))
    }

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack {
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
                        Label("Choose a working directory", systemImage: "folder.badge.questionmark")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 0) {
                    DraftPromptEditor(
                        text: $model.prompt,
                        isEnabled: model.isPromptEnabled,
                        focusID: model.promptFocusID,
                        canSend: model.canSend
                    ) {
                        Task { await model.send() }
                    }

                    Divider()

                    HStack {
                        ScrollView(.horizontal) {
                            HStack {
                                Picker(selection: $model.selectedProviderID) {
                                    ForEach(model.nativeProviders, id: \.instanceID) { provider in
                                        Text(provider.name).tag(Optional(provider.instanceID))
                                    }
                                    if !model.acpAgentChoices.isEmpty {
                                        Text("ACP").tag(Optional("acp"))
                                    }
                                } label: {
                                    Label(model.providerLabel, systemImage: "server.rack")
                                }
                                .pickerStyle(.menu)
                                .fixedSize()
                                .disabled(model.isSending)
                                .accessibilityLabel("Provider")

                                if model.usesACPProvider {
                                    Picker(selection: $model.selectedACPAgentID) {
                                        ForEach(model.acpAgentChoices) { agent in
                                            Text(agent.name).tag(Optional(agent.id))
                                        }
                                    } label: {
                                        Label(model.acpAgentLabel, systemImage: "person.crop.circle")
                                    }
                                    .pickerStyle(.menu)
                                    .fixedSize()
                                    .disabled(model.isSending)
                                    .accessibilityLabel("ACP agent")
                                }

                                ForEach(model.configOptions, id: \.id) { option in
                                    DraftConfigOptionView(option: option) { value in
                                        model.updateConfig(option.id, value: value)
                                    }
                                    .disabled(model.configControlsAreDisabled)
                                }

                                switch model.optionsPhase {
                                case .loading:
                                    ProgressView(model.optionsLoadingLabel)
                                        .font(.callout)
                                case .failed(let message):
                                    Label(message, systemImage: "exclamationmark.triangle")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Button("Retry settings", action: model.retryOptions)
                                case .unavailable, .live:
                                    EmptyView()
                                }

                                Menu {
                                    if !model.recentWorkingDirectories.isEmpty {
                                        ForEach(model.recentWorkingDirectories, id: \.self) { directory in
                                            Button(directory) {
                                                model.workingDirectory = directory
                                            }
                                        }
                                        Divider()
                                    }

                                    Button("Enter a path…") {
                                        model.beginEnteringDirectory()
                                    }
                                } label: {
                                    Label(model.directoryLabel, systemImage: "folder")
                                        .lineLimit(1)
                                }
                                .fixedSize()
                                .disabled(model.isSending)
                                .accessibilityLabel("Working directory")
                            }
                        }
                        .scrollIndicators(.hidden)

                        Spacer()

                        Button(
                            "Start chat",
                            systemImage: model.isSending ? "hourglass" : "arrow.up"
                        ) {
                            Task { await model.send() }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .disabled(!model.canSend)
                    }
                    .padding()
                }
                .background(.background)
                .clipShape(.rect(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(.quaternary, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.06), radius: 16, y: 6)
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
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

#if DEBUG
#Preview("Draft Prompt") {
    DraftPromptView(
        store: ThreadStore(previewThreads: PreviewData.threads),
        draftStore: ThreadDraftStore()
    )
}
#endif
