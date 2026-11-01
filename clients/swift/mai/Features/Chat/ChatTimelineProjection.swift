import Foundation

/// Incrementally maintains `ChatTimelineLayout.sections` for one thread's
/// turns: one section per turn.
///
/// Live events change the running turn at the tail; a snapshot, a refresh or
/// an older page replaces the turns wholesale. The session reports the
/// lowest turn index each event changed, so streaming reprojects only that
/// turn instead of re-walking every loaded turn on the main thread.
///
/// Reuse is exact: `invalidate(fromTurn:)` lowers the watermark and
/// `invalidateAll()` forces a full rebuild.
final class ChatTimelineProjection {
    // Explicit nonisolated destruction avoids the older Swift runtime's
    // task-local/isolated-deinit crash (swiftlang/swift#88036). This cache
    // owns values and has no actor-bound cleanup.
    nonisolated deinit {}

    private var sections: [ChatTimelineLayout.Section] = []
    /// Lowest turn index that may differ from what was last projected.
    /// `Int.max` means nothing is pending.
    private var firstChangedIndex = 0

    func invalidate(fromTurn index: Int) {
        firstChangedIndex = min(firstChangedIndex, index)
    }

    func invalidateAll() {
        firstChangedIndex = 0
    }

    /// Projects `turns`, reusing the sections of turns known unchanged, and
    /// clears the pending watermark.
    func project(_ turns: [TurnView]) -> [ChatTimelineLayout.Section] {
        defer { firstChangedIndex = .max }
        let keep = min(firstChangedIndex, sections.count, turns.count)
        sections.removeSubrange(keep...)
        for turn in turns[keep...] {
            sections.append(ChatTimelineLayout.section(for: turn))
        }
        return sections
    }
}
