import SwiftUI

struct ChatComposerControlsView: View {
    let session: SessionBinding?
    let model: ChatPromptModel

    @State private var isOptionsPresented = false

    var body: some View {
        if !configOptions.isEmpty {
            ComposerOptionsButton(
                summary: selectionSummary,
                isPresented: $isOptionsPresented
            ) {
                ComposerOptionsSheet(
                    options: configOptions,
                    commands: session?.slashCommands ?? [],
                    tokenUsage: session?.tokenUsage,
                    isOptionDisabled: { option in
                        model.isSettingConfigOption(option.id)
                    },
                    setValue: { option, value in
                        Task {
                            await model.setConfigOption(option.id, value: value)
                        }
                    },
                    insertCommand: model.insertSlashCommand
                )
            }
        }
    }

    private var configOptions: [ConfigOption] {
        session?.configOptions ?? []
    }

    private var selectionSummary: String {
        configOptions.selectionSummary ?? "Options"
    }
}
