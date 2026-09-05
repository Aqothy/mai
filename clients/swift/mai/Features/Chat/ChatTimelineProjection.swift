import Foundation

/// Incrementally maintains `ChatTimelineLayout.sections` for one thread's
/// timeline.
///
/// Live events mutate or append entries at the tail; restored history and
/// refresh snapshots replace entries wholesale. The session reports the
/// lowest index each event changed, so steady-state streaming reprojects only
/// the changed suffix instead of re-walking every historical entry on the
/// main thread for each structural event (about 5 ms per event at 2,500
/// entries and 20 ms at 10,000 in a debug build).
///
/// Reuse is exact, not heuristic: `invalidate(from:)` lowers the watermark
/// and `invalidateAll()` forces a full rebuild. The projection owns the
/// watermark, so projecting and consuming it is one atomic step on the
/// caller's timeline value.
final class ChatTimelineProjection {
    private var sections: [ChatTimelineLayout.Section] = []
    /// Entry index where the section at the same position begins.
    private var sectionStarts: [Int] = []
    private var consumedEntryCount = 0
    /// Lowest entry index that may differ from what was last projected.
    /// `Int.max` means nothing is pending.
    private var firstChangedIndex = 0

    /// Records that entries at or after `index` changed. Appends report the
    /// index the new entry occupies.
    func invalidate(from index: Int) {
        firstChangedIndex = min(firstChangedIndex, index)
    }

    /// Records that the timeline was replaced rather than appended to.
    func invalidateAll() {
        firstChangedIndex = 0
    }

    /// Projects `timeline`, reusing cached sections that cover only entries
    /// known to be unchanged, and clears the pending watermark.
    func project(_ timeline: [TimelineEntry]) -> [ChatTimelineLayout.Section] {
        defer { firstChangedIndex = .max }

        // Cached sections stay valid up to whichever ends first: the
        // watermark, what was previously consumed, or the timeline itself. A
        // timeline that shrank without `invalidateAll` is rebuilt defensively.
        let resumeIndex = min(firstChangedIndex, consumedEntryCount, timeline.count)
        if resumeIndex == 0 || timeline.count < consumedEntryCount {
            sections.removeAll(keepingCapacity: true)
            sectionStarts.removeAll(keepingCapacity: true)
            consumedEntryCount = 0
        } else {
            truncate(toEntryCount: resumeIndex)
        }

        for entry in timeline[consumedEntryCount...] {
            let sectionCountBefore = sections.count
            ChatTimelineLayout.project(entry, into: &sections)
            if sections.count > sectionCountBefore {
                sectionStarts.append(consumedEntryCount)
            }
            consumedEntryCount += 1
        }
        return sections
    }

    /// Drops cached sections that cover any entry at or beyond `targetCount`.
    /// A section straddling the boundary is dropped whole and its entries are
    /// read again.
    private func truncate(toEntryCount targetCount: Int) {
        while let start = sectionStarts.last,
            let last = sections.last,
            start + last.entryCount > targetCount
        {
            sections.removeLast()
            sectionStarts.removeLast()
        }
        if let start = sectionStarts.last, let last = sections.last {
            consumedEntryCount = start + last.entryCount
        } else {
            consumedEntryCount = 0
        }
    }
}
