#if DEBUG
    import Foundation

    /// What the benchmarks report beside frame times: rows that reached the
    /// screen before being prepared (PLAN D3 wants none at ≤ 8000 pt/s).
    @MainActor
    enum TranscriptDebugCounters {
        /// A row that was already in the transcript mounted while visible:
        /// drawn in that frame instead of ahead of it.
        static var syncFallbackDraws = 0
        /// A row that just arrived (a streamed block, a new entry) drawn in
        /// the frame it appears: new content, not a miss.
        static var arrivalDraws = 0
        /// A visible row laid out on the main thread because no layout had
        /// landed.
        static var syncLayouts = 0
        /// Visible rows shown at another width than the column's at the last
        /// placement: how far reflow lags behind a resize.
        static var staleVisibleRows = 0
        /// How far, in points, the visible row laid out farthest from the
        /// column's width was at the last placement: how far reflow trails.
        static var visibleWidthLag: CGFloat = 0
        /// Visible rows placed at another height than their layout's, summed
        /// over placements: rows overlapping or a gap between them.
        static var misplacedRows = 0
    }
#endif
