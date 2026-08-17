import SwiftUI

struct SearchableSelectionSheet: View {
    let title: String
    let selectedID: String?
    let clearSelectionTitle: String?
    let emptyTitle: String
    let actionTitle: String?
    let actionSystemImage: String
    let onSelect: (String?) -> Void
    let onAction: (() -> Void)?

    @State private var model: SearchableSelectionModel
    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        choices: [SearchableSelectionChoice],
        selectedID: String? = nil,
        clearSelectionTitle: String? = nil,
        emptyTitle: String,
        actionTitle: String? = nil,
        actionSystemImage: String = "plus",
        onSelect: @escaping (String?) -> Void,
        onAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.selectedID = selectedID
        self.clearSelectionTitle = clearSelectionTitle
        self.emptyTitle = emptyTitle
        self.actionTitle = actionTitle
        self.actionSystemImage = actionSystemImage
        self.onSelect = onSelect
        self.onAction = onAction
        _model = State(initialValue: SearchableSelectionModel(choices: choices))
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            List {
                if let actionTitle, let onAction {
                    Button(actionTitle, systemImage: actionSystemImage, action: onAction)
                }

                if let clearSelectionTitle {
                    Button {
                        onSelect(nil)
                        dismiss()
                    } label: {
                        HStack {
                            Text(clearSelectionTitle)
                            Spacer()
                            if selectedID == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(model.visibleChoices) { choice in
                    Button {
                        onSelect(choice.id)
                        dismiss()
                    } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(choice.title)
                                    if let subtitle = choice.subtitle,
                                        subtitle != choice.title
                                    {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            } icon: {
                                Image(systemName: choice.systemImage)
                            }
                            Spacer()
                            if selectedID == choice.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }

                if model.visibleChoices.isEmpty {
                    if model.searchText.isEmpty {
                        ContentUnavailableView(emptyTitle, systemImage: "magnifyingglass")
                    } else {
                        ContentUnavailableView.search(text: model.searchText)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $model.searchText, prompt: "Search")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .tint(.accentColor)
        .foregroundStyle(.primary)
    }
}
