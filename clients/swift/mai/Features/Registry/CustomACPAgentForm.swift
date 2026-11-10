import Foundation
import Observation
import SwiftUI

struct CustomACPAgentForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: CustomACPAgentFormModel
    @FocusState private var isTextFieldFocused: Bool

    init(store: ThreadStore, editing agent: ACPRegistryAgent? = nil) {
        _model = State(initialValue: CustomACPAgentFormModel(store: store, editing: agent))
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Agent") {
                TextField("Name", text: $model.name, prompt: Text("My Agent"))
                    .focused($isTextFieldFocused)
                if let collisionMessage = model.nameCollisionMessage {
                    Text(collisionMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                TextField(
                    "Command",
                    text: $model.command,
                    prompt: Text("/path/to/agent")
                )
                .textContentType(.none)
                .autocorrectionDisabled()
                .monospaced()
                .focused($isTextFieldFocused)
                TextField(
                    "Arguments",
                    text: $model.argumentText,
                    prompt: Text("--flag value"),
                    axis: .vertical
                )
                .textContentType(.none)
                .autocorrectionDisabled()
                .monospaced()
                .focused($isTextFieldFocused)
                Text("Separate flags and values with spaces, for example: --acp --profile work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Environment Variables") {
                ForEach(model.environmentVariables) { variable in
                    CustomACPEnvironmentVariableRow(
                        variable: variable,
                        isTextFieldFocused: $isTextFieldFocused
                    ) {
                        model.removeEnvironmentVariable(id: variable.id)
                    }
                }
                Button("Add Variable", systemImage: "plus") {
                    model.addEnvironmentVariable()
                }
            }
        }
        .onSubmit { isTextFieldFocused = false }
        .navigationTitle(model.isEditing ? "Edit Custom Agent" : "Add Custom Agent")
        .inlineNavigationBarTitle()
        .interactiveDismissDisabled(model.isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .disabled(model.isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task {
                        if await model.save() {
                            dismiss()
                        }
                    }
                } label: {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Text(model.isEditing ? "Save" : "Add")
                    }
                }
                .accessibilityLabel(model.isEditing ? "Save" : "Add")
                .disabled(!model.canSave)
            }
        }
        .alert(model.isEditing ? "Couldn’t Save Agent" : "Couldn’t Add Agent", isPresented: $model.isErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "An unknown error occurred.")
        }
    }
}

@Observable
private final class CustomACPAgentFormModel {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    var name = ""
    var command = ""
    var argumentText = ""
    private(set) var environmentVariables: [CustomACPEnvironmentVariable] = []
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    private let store: ThreadStore
    /// The custom agent this form edits; nil when it adds one.
    private let editedID: String?

    var isEditing: Bool { editedID != nil }

    init(store: ThreadStore, editing agent: ACPRegistryAgent?) {
        self.store = store
        editedID = agent?.id
        guard let agent else { return }
        name = agent.name
        command = agent.command ?? ""
        argumentText = (agent.args ?? []).joined(separator: " ")
        environmentVariables = (agent.envNames ?? []).map(CustomACPEnvironmentVariable.init(existing:))
    }

    var isErrorPresented: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    var nameCollisionMessage: String? {
        guard let collidingAgentName else { return nil }
        return CustomACPAgentValidationError.duplicateAgentName(collidingAgentName).errorDescription
    }

    private var collidingAgentName: String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return store.installedAgents.first {
            $0.source == MaidACPAgentSource.custom.rawValue && $0.name == name && $0.id != editedID
        }?.name
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && collidingAgentName == nil
            && !isSaving
    }

    func addEnvironmentVariable() {
        environmentVariables.append(CustomACPEnvironmentVariable())
    }

    func removeEnvironmentVariable(id: UUID) {
        environmentVariables.removeAll { $0.id == id }
    }

    func save() async -> Bool {
        guard !isSaving else { return false }

        do {
            if let collidingAgentName {
                throw CustomACPAgentValidationError.duplicateAgentName(collidingAgentName)
            }
            let configuration = try CustomACPAgentConfiguration(
                name: name,
                command: command,
                argumentText: argumentText,
                environment: environmentVariables.filter { !$0.keepsExistingValue }.map { ($0.key, $0.value) },
                keeping: environmentVariables.filter(\.keepsExistingValue).map(\.key)
            )
            isSaving = true
            defer { isSaving = false }
            if let editedID {
                try await store.updateCustomACPAgent(id: editedID, configuration: configuration)
            } else {
                try await store.addCustomACPAgent(configuration)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct CustomACPAgentConfiguration: Equatable {
    let name: String
    let command: String
    let arguments: [String]
    let environment: [String: String]
    /// Existing variables that stay as they are; the client never sees their
    /// values.
    let keptEnvironment: [String]

    init(
        name: String,
        command: String,
        argumentText: String,
        environment: [(key: String, value: String)],
        keeping keptEnvironment: [String] = []
    ) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw CustomACPAgentValidationError.missingName
        }

        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw CustomACPAgentValidationError.missingCommand
        }

        var environmentValues: [String: String] = [:]
        for pair in environment {
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            guard environmentValues[key] == nil, !keptEnvironment.contains(key) else {
                throw CustomACPAgentValidationError.duplicateEnvironmentVariable(key)
            }
            environmentValues[key] = pair.value
        }

        self.name = name
        self.command = command
        self.arguments = argumentText.split(whereSeparator: \.isWhitespace).map(String.init)
        self.environment = environmentValues
        self.keptEnvironment = keptEnvironment
    }
}

enum CustomACPAgentValidationError: LocalizedError, Equatable {
    case missingName
    case missingCommand
    case duplicateAgentName(String)
    case duplicateEnvironmentVariable(String)

    var errorDescription: String? {
        switch self {
        case .missingName:
            String(localized: "Agent name is required.")
        case .missingCommand:
            String(localized: "Command is required.")
        case .duplicateAgentName(let name):
            String(
                localized: "An agent named \(name) already exists.",
                comment:
                    "Validation error shown when naming an ACP agent with a name already used."
            )
        case .duplicateEnvironmentVariable(let key):
            String(
                localized: "Duplicate environment variable \(key).",
                comment: "Validation error. The variable is an environment variable name."
            )
        }
    }
}

@Observable
private final class CustomACPEnvironmentVariable: Identifiable {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    let id = UUID()
    /// Set on a variable the agent already has: its name can't change and its
    /// value is unknown here, so an empty value means leave it as it is.
    let isExisting: Bool
    var key: String
    var value = ""

    var keepsExistingValue: Bool { isExisting && value.isEmpty }

    init() {
        isExisting = false
        key = ""
    }

    init(existing name: String) {
        isExisting = true
        key = name
    }
}

private struct CustomACPEnvironmentVariableRow: View {
    @Bindable var variable: CustomACPEnvironmentVariable
    let isTextFieldFocused: FocusState<Bool>.Binding
    let remove: () -> Void

    var body: some View {
        HStack {
            TextField("Name", text: $variable.key)
                .textContentType(.none)
                .autocorrectionDisabled()
                .monospaced()
                .focused(isTextFieldFocused)
                .disabled(variable.isExisting)
            TextField("Value", text: $variable.value, prompt: variable.isExisting ? Text("Unchanged") : nil)
                .textContentType(.none)
                .autocorrectionDisabled()
                .monospaced()
                .focused(isTextFieldFocused)
            Button("Remove Environment Variable", systemImage: "minus.circle", role: .destructive) {
                remove()
            }
            .labelStyle(.iconOnly)
        }
    }
}
