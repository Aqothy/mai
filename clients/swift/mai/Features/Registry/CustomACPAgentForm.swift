import Foundation
import Observation
import SwiftUI

struct CustomACPAgentForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: CustomACPAgentFormModel
    @FocusState private var isTextFieldFocused: Bool

    init(store: ThreadStore) {
        _model = State(initialValue: CustomACPAgentFormModel(store: store))
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
        .navigationTitle("Add Custom Agent")
        .navigationBarTitleDisplayMode(.inline)
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
                        Text("Add")
                    }
                }
                .accessibilityLabel("Add")
                .disabled(!model.canSave)
            }
        }
        .alert("Couldn’t Add Agent", isPresented: $model.isErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "An unknown error occurred.")
        }
    }
}

@Observable
private final class CustomACPAgentFormModel {
    var name = ""
    var command = ""
    var argumentText = ""
    private(set) var environmentVariables: [CustomACPEnvironmentVariable] = []
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    private let store: ThreadStore

    init(store: ThreadStore) {
        self.store = store
    }

    var isErrorPresented: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    var nameCollisionMessage: String? {
        guard let collidingAgentID else { return nil }
        return CustomACPAgentValidationError.duplicateAgentName(collidingAgentID).errorDescription
    }

    private var collidingAgentID: String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return store.installedAgents.first { $0.id == name }?.id
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && collidingAgentID == nil
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
            if let collidingAgentID {
                throw CustomACPAgentValidationError.duplicateAgentName(collidingAgentID)
            }
            let configuration = try CustomACPAgentConfiguration(
                name: name,
                command: command,
                argumentText: argumentText,
                environment: environmentVariables.map { ($0.key, $0.value) }
            )
            isSaving = true
            defer { isSaving = false }
            _ = try await store.addCustomACPAgent(configuration)
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

    init(
        name: String,
        command: String,
        argumentText: String,
        environment: [(key: String, value: String)]
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
            guard environmentValues[key] == nil else {
                throw CustomACPAgentValidationError.duplicateEnvironmentVariable(key)
            }
            environmentValues[key] = pair.value
        }

        self.name = name
        self.command = command
        self.arguments = argumentText.split(whereSeparator: \.isWhitespace).map(String.init)
        self.environment = environmentValues
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
                    "Validation error shown when adding an ACP agent whose name is already used."
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
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
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
            TextField("Value", text: $variable.value)
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
