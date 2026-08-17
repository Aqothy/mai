import SwiftUI

struct FolderPickerView: View {
    let title: String
    let confirmationTitle: String
    let onCancel: (() -> Void)?
    let onSelect: (String, String?) -> Void

    @State private var model: FolderPickerModel
    @Environment(\.dismiss) private var dismiss

    init(
        store: ThreadStore,
        projectFolders: ProjectFolderStore,
        title: String = "Add Project Folder",
        confirmationTitle: String = "Add",
        onCancel: (() -> Void)? = nil,
        onSelect: @escaping (String, String?) -> Void
    ) {
        self.title = title
        self.confirmationTitle = confirmationTitle
        self.onCancel = onCancel
        self.onSelect = onSelect
        _model = State(
            initialValue: FolderPickerModel(
                store: store,
                projectFolders: projectFolders
            )
        )
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            List {
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

                if let parentPath = model.parentPath {
                    Button("Parent Folder", systemImage: "arrow.turn.left.up") {
                        Task { await model.browse(parentPath) }
                    }
                }

                ForEach(model.visibleEntries, id: \.path) { entry in
                    Button {
                        Task { await model.browse(entry.path) }
                    } label: {
                        HStack {
                            Label(entry.name, systemImage: "folder")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }

                if model.visibleEntries.isEmpty,
                    model.currentPath != nil,
                    !model.isLoading
                {
                    if model.searchText.isEmpty {
                        ContentUnavailableView(
                            "No Subfolders",
                            systemImage: "folder"
                        )
                    } else {
                        ContentUnavailableView.search(text: model.searchText)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $model.searchText, prompt: "Search Folders")
            .overlay {
                if model.isInitialLoading {
                    ProgressView("Loading Folders…")
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        onCancel == nil ? "Cancel" : "Back",
                        systemImage: onCancel == nil ? "xmark" : "chevron.left"
                    ) {
                        if let onCancel {
                            onCancel()
                        } else {
                            dismiss()
                        }
                    }
                    .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .principal) {
                    Text(model.currentFolderName ?? title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Menu(
                        "Pinned Locations",
                        systemImage: model.currentFolderIsRemembered ? "pin.fill" : "pin"
                    ) {
                        if model.currentFolderIsRemembered {
                            Button(
                                "Unpin Current Location",
                                systemImage: "pin.slash"
                            ) {
                                model.forgetCurrentFolder()
                            }
                        } else {
                            Button(
                                "Pin Current Location",
                                systemImage: "pin"
                            ) {
                                model.rememberCurrentFolder()
                            }
                            .disabled(model.currentPath == nil)
                        }

                        if !model.parentFolders.isEmpty {
                            Divider()
                            ForEach(model.parentFolders, id: \.self) { path in
                                Button {
                                    Task { await model.browse(path) }
                                } label: {
                                    if path == model.currentPath {
                                        Label(path, systemImage: "checkmark")
                                    } else {
                                        Label(path, systemImage: "folder")
                                    }
                                }
                            }
                        }
                    }
                    .labelStyle(.iconOnly)

                    Button(confirmationTitle, systemImage: "checkmark") {
                        guard let currentPath = model.currentPath else { return }
                        onSelect(currentPath, model.parentPath)
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!model.canSelectCurrentFolder)
                }
            }
            .task {
                await model.loadInitialPath()
            }
        }
        .tint(.accentColor)
        .foregroundStyle(.primary)
    }
}
