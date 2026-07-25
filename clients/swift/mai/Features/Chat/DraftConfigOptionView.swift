import SwiftUI

struct DraftConfigOptionView: View {
    let option: ConfigOption
    let setValue: (JSONAny) -> Void

    var body: some View {
        if option.optionType == .boolean {
            Toggle(option.label ?? option.id, isOn: booleanValue)
                .fixedSize()
        } else if let choices = option.choices, !choices.isEmpty {
            Picker(selection: stringValue) {
                ForEach(choices, id: \.value) { choice in
                    Text(choice.label ?? choice.value).tag(choice.value)
                }
            } label: {
                Label(option.label ?? option.id, systemImage: icon)
            }
            .pickerStyle(.menu)
            .fixedSize()
        } else {
            Text("\(option.label ?? option.id): \(displayValue)")
                .foregroundStyle(.secondary)
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

    private var icon: String {
        switch option.optionCategory {
        case .model: "cpu"
        case .mode: "slider.horizontal.3"
        case .thoughtLevel: "brain"
        case .modelConfig: "dial.medium"
        // .other and any category this build predates.
        default: "gearshape"
        }
    }
}
