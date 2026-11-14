#if os(macOS) && DEBUG
    import AppKit

    /// Row geometry the benchmarks check a row's position against.
    @MainActor
    protocol ChatBenchmarkRowGeometry: NSView {
        var numberOfRows: Int { get }
        func rect(ofRow row: Int) -> NSRect
        func rows(in rect: NSRect) -> NSRange
        func stableIdentity(forRow row: Int) -> String?
        func row(forStableIdentity id: String) -> Int?
    }

    extension ChatNativeTranscript.VirtualDocument: ChatBenchmarkRowGeometry {
        func stableIdentity(forRow row: Int) -> String? {
            geometry.ids.indices.contains(row) ? geometry.ids[row] : nil
        }

        func row(forStableIdentity id: String) -> Int? { geometry.index(for: id) }

        func rect(ofRow index: Int) -> NSRect {
            guard index >= 0, index < numberOfRows else { return .zero }
            return NSRect(
                x: 0, y: offsets[index], width: bounds.width,
                height: offsets[index + 1] - offsets[index])
        }

        func rows(in rect: NSRect) -> NSRange {
            guard numberOfRows > 0, rect.maxY > 0, rect.minY < bounds.height else {
                return NSRange(location: NSNotFound, length: 0)
            }
            let first = row(at: max(0, rect.minY))
            let last = row(at: min(bounds.height, rect.maxY).nextDown)
            return NSRange(location: first, length: max(0, last - first + 1))
        }
    }
#endif
