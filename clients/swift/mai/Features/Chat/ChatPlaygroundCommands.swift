#if DEBUG
    import SwiftUI

    /// A Debug menu for trying the transcript by hand in the synthetic chat
    /// (`-ChatBenchmarkSyntheticTurns <n>` without `-ChatAutoBenchmark`):
    /// streams a reply with code and tables as a new turn, at
    /// `-ChatPlaygroundCharactersPerSecond` (300 by default, about what chat
    /// apps stream; the benchmark streams 1000).
    struct ChatPlaygroundCommands: Commands {
        let store: ThreadStore
        @State private var streamCount = 0
        @State private var isStreaming = false

        private static var charactersPerSecond: Double {
            let value = UserDefaults.standard.double(forKey: "ChatPlaygroundCharactersPerSecond")
            return value > 0 ? value : 300
        }

        var body: some Commands {
            CommandMenu("Playground") {
                Button("Stream a Reply") { stream(includesActivity: false) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(isStreaming)
                Button("Stream Thoughts, a Tool and a Reply") { stream(includesActivity: true) }
                    .keyboardShortcut("r", modifiers: [.command, .option, .shift])
                    .disabled(isStreaming)
            }
        }

        private func stream(includesActivity: Bool) {
            streamCount += 1
            isStreaming = true
            let driver = ChatSyntheticStreamingBenchmark(
                store: store, includesActivity: includesActivity, charactersPerSecond: Self.charactersPerSecond,
                turnID: "playground-turn-\(streamCount)")
            driver.prepare()
            Task {
                await driver.run()
                isStreaming = false
            }
        }
    }
#endif
