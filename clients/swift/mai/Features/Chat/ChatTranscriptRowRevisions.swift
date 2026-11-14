import Foundation

/// Which height report each row's mounted view may still make. A hosted row
/// reports its height from inside its own SwiftUI layout, possibly after an
/// install gave the row new content; a report carrying an older revision
/// describes content that is gone and is dropped.
nonisolated struct ChatTranscriptRowRevisions {
    private var revisions: [String: Int] = [:]
    private var next = 0

    subscript(id: String) -> Int? { revisions[id] }

    /// After an install: forgets rows that left and gives `invalidatedIDs`
    /// new revisions. An unchanged live row keeps its revision across parent
    /// updates; otherwise a height it has queued would be dropped for good.
    mutating func install(
        invalidatedIDs: some Sequence<String>, rowsChanged: Bool,
        in geometry: ChatVirtualTranscriptGeometry
    ) {
        if rowsChanged {
            revisions = revisions.filter { geometry.index(for: $0.key) != nil }
        }
        for id in invalidatedIDs {
            next += 1
            revisions[id] = next
        }
    }

    /// Whether a mounted row's report is current and changes its height.
    func accepts(
        _ height: CGFloat, id: String, revision: Int, in geometry: ChatVirtualTranscriptGeometry
    ) -> Bool {
        guard height.isFinite, height > 0, revisions[id, default: 0] == revision,
            let index = geometry.index(for: id)
        else { return false }
        return geometry.heights[index] != height
    }
}
