#if os(macOS) && DEBUG
    import AppKit

    extension TranscriptDocumentView: ChatBenchmarkAnchoredDocument, ChatBenchmarkRowGeometry {
        /// The old transcript's row count for the 300-turn synthetic chat:
        /// benchmark anchors are given in its rows, and land at the same
        /// fraction of this transcript.
        private static let anchorRowScale: Double = 5_850

        func scrollToBenchmarkRow(_ index: Int) {
            let count = controller.geometry.count
            guard count > 0 else { return }
            let row = min(count - 1, Int(Double(index) / Self.anchorRowScale * Double(count)))
            setViewportTop(controller.geometry.offset(at: row))
        }

        var benchmarkStatistics: String {
            "newEngine rows=\(controller.geometry.count) mounted=\(mountedRowCount) layouts=\(controller.layouts.count) syncFallbackDraws=\(TranscriptDebugCounters.syncFallbackDraws) syncLayouts=\(TranscriptDebugCounters.syncLayouts)"
        }

        var numberOfRows: Int { controller.geometry.count }

        func rect(ofRow row: Int) -> NSRect {
            guard row >= 0, row < controller.geometry.count else { return .zero }
            let frame = controller.geometry.frame(at: row)
            return NSRect(x: 0, y: frame.minY, width: bounds.width, height: frame.height)
        }

        func rows(in rect: NSRect) -> NSRange {
            guard let range = controller.geometry.indices(overlapping: max(0, rect.minY), rect.maxY) else {
                return NSRange(location: NSNotFound, length: 0)
            }
            return NSRange(location: range.lowerBound, length: range.count)
        }

        func stableIdentity(forRow row: Int) -> String? {
            controller.geometry.ids.indices.contains(row) ? controller.geometry.ids[row] : nil
        }

        func row(forStableIdentity id: String) -> Int? { controller.geometry.index(for: id) }
    }
#endif
