import CoreGraphics
import Foundation

/// Which transcript a chat shows. The rewrite runs behind the DEBUG launch
/// argument `-ChatTranscriptEngine new` until it replaces the old one, so
/// the same harness drives both.
nonisolated enum TranscriptEngine {
    static var isNewEngineEnabled: Bool {
        #if DEBUG
            UserDefaults.standard.string(forKey: "ChatTranscriptEngine") == "new"
        #else
            false
        #endif
    }
}
