import SwiftUI

extension [ConfigOption] {
    /// The "Model · Thought level" style summary shown on composer controls,
    /// or nil when neither preferred category has a selection.
    var selectionSummary: String? {
        let preferredCategories: [MaidConfigOptionCategory] = [.model, .thoughtLevel]
        let values = preferredCategories.compactMap { category in
            first { $0.optionCategory == category }?.selectedChoiceLabel
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }
}

struct ComposerOptionsSheet: View {
    let options: [ConfigOption]
    let commands: [SlashCommand]
    let tokenUsage: TokenUsage?
    let isOptionDisabled: (ConfigOption) -> Bool
    let setValue: (ConfigOption, JSONAny) -> Void
    let insertCommand: (SlashCommand) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        options: [ConfigOption],
        commands: [SlashCommand] = [],
        tokenUsage: TokenUsage? = nil,
        isOptionDisabled: @escaping (ConfigOption) -> Bool = { _ in false },
        setValue: @escaping (ConfigOption, JSONAny) -> Void,
        insertCommand: @escaping (SlashCommand) -> Void = { _ in }
    ) {
        self.options = options
        self.commands = commands
        self.tokenUsage = tokenUsage
        self.isOptionDisabled = isOptionDisabled
        self.setValue = setValue
        self.insertCommand = insertCommand
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if options.isEmpty {
                        Label(
                            "This provider does not expose additional options.",
                            systemImage: "slider.horizontal.3"
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(options, id: \.id) { option in
                            DraftConfigOptionView(option: option) { value in
                                setValue(option, value)
                            }
                            .disabled(isOptionDisabled(option))
                        }
                    }

                    if !commands.isEmpty {
                        Picker(selection: commandSelection) {
                            Text("Choose").tag("")
                            ForEach(commands, id: \.name) { command in
                                Text("/\(command.name)").tag(command.name)
                            }
                        } label: {
                            Label {
                                Text("Insert command")
                            } icon: {
                                Image(systemName: "slash.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.secondary)
                    }

                    if let tokenUsage {
                        ChatTokenUsageView(usage: tokenUsage)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    // Intentional picker-as-menu: the always-empty get keeps "Choose"
    // displayed, and each selection fires an insert action instead of
    // persisting state — a keypath binding cannot express this.
    private var commandSelection: Binding<String> {
        Binding(
            get: { "" },
            set: { commandName in
                guard let command = commands.first(where: { $0.name == commandName }) else {
                    return
                }
                insertCommand(command)
                dismiss()
            }
        )
    }
}

#if DEBUG
    #Preview("Provider Options") {
        ComposerOptionsSheet(
            options: [
                ConfigOption(
                    category: MaidConfigOptionCategory.model.rawValue,
                    choices: [
                        ConfigChoice(label: "5.6 Terra", value: "terra"),
                        ConfigChoice(label: "5.6 Sol", value: "sol"),
                    ],
                    currentValue: JSONAny("terra"),
                    description: "The model used for this chat",
                    id: "model",
                    label: "Model",
                    type: MaidConfigOptionType.select.rawValue
                ),
                ConfigOption(
                    category: MaidConfigOptionCategory.thoughtLevel.rawValue,
                    choices: [
                        ConfigChoice(label: "Low", value: "low"),
                        ConfigChoice(label: "Medium", value: "medium"),
                        ConfigChoice(label: "High", value: "high"),
                    ],
                    currentValue: JSONAny("medium"),
                    description: "How deeply the model reasons",
                    id: "thinking",
                    label: "Thinking",
                    type: MaidConfigOptionType.select.rawValue
                ),
                ConfigOption(
                    category: MaidConfigOptionCategory.modelConfig.rawValue,
                    choices: nil,
                    currentValue: JSONAny(true),
                    description: "Use the provider's faster response path",
                    id: "fast_mode",
                    label: "Fast mode",
                    type: MaidConfigOptionType.boolean.rawValue
                ),
            ],
            commands: [
                SlashCommand(description: nil, hasInput: false, name: "compact")
            ],
            tokenUsage: TokenUsage(
                cost: nil,
                currency: nil,
                maxTokens: 200_000,
                usedTokens: 48_200
            ),
            setValue: { _, _ in },
            insertCommand: { _ in }
        )
    }
#endif

private struct DraftConfigOptionView: View {
    let option: ConfigOption
    let setValue: (JSONAny) -> Void

    var body: some View {
        if option.optionType == .boolean {
            Toggle(isOn: booleanValue) {
                ConfigOptionLabel(option: option)
            }
        } else if let choices = option.choices, !choices.isEmpty {
            Picker(selection: stringValue) {
                ForEach(choices, id: \.value) { choice in
                    Text(choice.label ?? choice.value).tag(choice.value)
                }
            } label: {
                ConfigOptionLabel(option: option)
            }
            .pickerStyle(.menu)
            .tint(.secondary)
        } else {
            LabeledContent {
                Text(displayValue)
                    .foregroundStyle(.secondary)
            } label: {
                ConfigOptionLabel(option: option)
            }
        }
    }

    private var booleanValue: Binding<Bool> {
        Binding(
            get: { option.currentValue?.value as? Bool ?? false },
            set: { setValue(JSONAny($0)) }
        )
    }

    private var stringValue: Binding<String> {
        Binding(
            get: { option.currentValue?.value as? String ?? "" },
            set: { setValue(JSONAny($0)) }
        )
    }

    private var displayValue: String {
        guard let value = option.currentValue?.value else { return "Unavailable" }
        return String(describing: value)
    }
}

private struct ConfigOptionLabel: View {
    let option: ConfigOption

    var body: some View {
        Label {
            Text(option.label ?? option.id)
                .lineLimit(1)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch option.optionCategory {
        case .model: "sparkles"
        case .mode: "slider.horizontal.3"
        case .thoughtLevel: "brain"
        case .modelConfig: "dial.medium"
        default: "gearshape"
        }
    }
}

private struct ChatTokenUsageView: View {
    let usage: TokenUsage

    var body: some View {
        LabeledContent {
            if let percentage {
                Text(percentage, format: .percent.precision(.fractionLength(0)))
            } else {
                Text(usage.usedTokens, format: .number.notation(.compactName))
            }
        } label: {
            Label {
                Text("Context window")
            } icon: {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Context usage")
    }

    private var percentage: Double? {
        guard let maxTokens = usage.maxTokens, maxTokens > 0 else { return nil }
        return min(Double(usage.usedTokens) / Double(maxTokens), 1)
    }
}
