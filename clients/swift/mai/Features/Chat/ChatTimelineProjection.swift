import Foundation

/// Incrementally maintains `ChatTimelineLayout.sections` for one thread's
/// timeline.
///
/// Live events mutate or append entries at the tail; restored history and
/// refresh snapshots replace entries wholesale. The store records the lowest
/// index that changed since the last projection, so steady-state streaming
/// reprojects only the changed suffix instead of re-walking every historical
/// entry on the main thread for each structural event.
///
/// Reuse is exact, not heuristic: any timeline mutation lowers the watermark,
/// and a watermark of zero (snapshot replacement) forces a full rebuild.
final class ChatTimelineProjection {
    private(set) var sections: [ChatTimelineLayout.Section] = []
    /// Entry index where the section at the same position begins.
    private var sectionStarts: [Int] = []
    private(set) var consumedEntryCount = 0

    var isEmpty: Bool { sections.isEmpty }

    /// Projects `timeline`, reusing cached sections that only cover entries
    /// known to be unchanged.
    ///
    /// - Parameters:
    ///   - timeline: The thread's current timeline.
    ///   - firstChangedIndex: Lowest entry index that may differ from what
    ///     this projection last consumed. Zero rebuilds everything; a value
    ///     at or beyond `timeline.count` means nothing changed.
    func project(
        timeline: [TimelineEntry],
        firstChangedIndex: Int
    ) -> [ChatTimelineLayout.Section] {
        let count = timeline.count
        guard firstChangedIndex > 0, count >= consumedEntryCount else {
            rebuild(timeline)
            return sections
        }

        // Mutations only touch indices at or after the watermark, so cached
        // sections remain valid up to whichever ends first: the watermark or
        // what was previously consumed. A section straddling that boundary is
        // dropped whole and its entries are read again.
        let resumeIndex = truncateToEntryCount(
            min(firstChangedIndex, consumedEntryCount)
        )
        for entry in timeline[resumeIndex...] {
            let sectionCountBefore = sections.count
            ChatTimelineLayout.project(entry, into: &sections)
            if sections.count > sectionCountBefore {
                sectionStarts.append(consumedEntryCount)
            }
            consumedEntryCount += 1
        }
        return sections
    }

    private func rebuild(_ timeline: [TimelineEntry]) {
        sections.removeAll()
        sectionStarts.removeAll()
        consumedEntryCount = 0
        project(timeline: timeline, firstChangedIndex: .max)
    }

    /// Drops cached sections covering entries at or beyond `targetCount`.
    /// Returns the entry index to resume from.
    private func truncateToEntryCount(_ targetCount: Int) -> Int {
        while let start = sectionStarts.last,
            let last = sections.last,
            start + last.entryCount > targetCount
        {
            sections.removeLast()
            sectionStarts.removeLast()
        }
        guard let start = sectionStarts.last, let last = sections.last else {
            consumedEntryCount = 0
            return 0
        }
        consumedEntryCount = start + last.entryCount
        return consumedEntryCount
    }
}
