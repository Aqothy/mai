import Foundation

nonisolated enum ChatTranscriptConfiguration {
    static var usesNativeMacTranscript: Bool {
        #if os(macOS)
            #if DEBUG
                !UserDefaults.standard.bool(forKey: "ChatBenchmarkUseList")
            #else
                true
            #endif
        #else
            false
        #endif
    }
}
