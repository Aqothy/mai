import CoreGraphics
import Foundation
import Synchronization

/// Parsed blocks by message source, process-wide and bounded: a chat opened
/// again, or another chat with the same text, skips parsing. A cache, so
/// everything works without it (`-ChatTranscriptCaches off`).
nonisolated final class MarkdownBlockCache: Sendable {
    static let shared = MarkdownBlockCache(budget: 32 * 1_024 * 1_024)

    private struct State {
        var entries: [String: (blocks: [MarkdownBlock], lastUse: UInt64)] = [:]
        var bytes = 0
        var clock: UInt64 = 0
    }

    private let budget: Int
    private let state = Mutex(State())

    init(budget: Int) {
        self.budget = budget
    }

    func blocks(for source: String) -> [MarkdownBlock]? {
        state.withLock { state in
            guard let entry = state.entries[source] else { return nil }
            state.clock += 1
            state.entries[source] = (entry.blocks, state.clock)
            return entry.blocks
        }
    }

    func insert(_ blocks: [MarkdownBlock], for source: String) {
        state.withLock { state in
            state.clock += 1
            if state.entries[source] == nil { state.bytes += source.utf8.count * 3 }
            state.entries[source] = (blocks, state.clock)
            guard state.bytes > budget else { return }
            let victims = state.entries.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(state.entries.count / 4 + 1)
            for (source, _) in victims {
                state.entries[source] = nil
                state.bytes -= source.utf8.count * 3
            }
        }
    }
}
