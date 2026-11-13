import Observation

/// Stable text storage for one actively streaming entry. The thread detail
/// still records every chunk, while the visible leaf row observes this
/// reference directly.
@Observable
final class ThreadStreamingText {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    private(set) var text: String
    /// Cheap task identity that avoids hashing the growing text on every chunk.
    private(set) var revision = 0

    init(text: String) {
        self.text = text
    }

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        text += delta
        revision += 1
    }
}
