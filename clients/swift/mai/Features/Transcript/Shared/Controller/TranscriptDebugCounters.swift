#if DEBUG
    import Foundation

    /// What the benchmarks report beside frame times: rows shown at a stale
    /// width or height.
    @MainActor
    enum TranscriptDebugCounters {
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
