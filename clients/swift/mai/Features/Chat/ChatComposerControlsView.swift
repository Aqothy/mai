import SwiftUI

struct ChatComposerControlsView: View {
    /// The agent the composer talks to.
    let participant: ParticipantView?
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
                    commands: participant?.commands ?? [],
                    tokenUsage: participant?.usage,
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
        participant?.options ?? []
    }

    private var selectionSummary: String {
        configOptions.selectionSummary ?? "Options"
    }
}
