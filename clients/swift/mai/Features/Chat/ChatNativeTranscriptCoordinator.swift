import SwiftUI

extension ChatNativeTranscript {
    /// Turns one published set of rows into complete geometry: rows whose
    /// inputs changed are measured, and the document receives every height
    /// in a single install. AppKit and UIKit share this; only the document
    /// and the view that measures a SwiftUI row differ.
    final class Coordinator {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        let virtualDocument = VirtualDocument()
        var task: Task<Void, Never>?
        struct Measurement {
            let key: ChatNativeRowMeasurementKey?
            let width: CGFloat
            let height: CGFloat
        }
        var measurements: [String: Measurement] = [:]
        private var presentationTheme: ChatCodeHighlightTheme?
        private var layoutStore: ObjectIdentifier?
        private(set) var lastMeasuredRowCount = 0

        func update(
            ids: [String], width: CGFloat, measurementKeys: [ChatNativeRowMeasurementKey?] = [],
            presentationTheme: ChatCodeHighlightTheme? = nil,
            layoutStore: ObjectIdentifier? = nil,
            nativeRowHeight: ((Int, CGFloat) -> CGFloat?)? = nil,
            nativeRowFactory: ((Int, ChatPlatformView?) -> ChatPlatformView?)?,
            onAttach: ((ChatTranscriptScrollDocument) -> Void)?,
            content: @escaping (Int) -> Content
        ) {
            guard width > 0 else { return }
            if ids.isEmpty {
                task?.cancel()
                measurements.removeAll()
                virtualDocument.install(heights: [], width: width, content: content)
                return
            }
            task?.cancel()
            #if DEBUG
                ChatBenchmarkAutoRun.isNativeGeometryWarm = false
            #endif
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                #if DEBUG
                    let started = ContinuousClock.now
                #endif
                // Most updates measure nothing, so the view that sizes a
                // SwiftUI row is only built for the first row that needs it.
                let measure = self.virtualDocument.makeRowMeasurer()
                var result: [CGFloat] = []
                var updatedMeasurements: [String: Measurement] = [:]
                // A new layout store holds layouts at other fonts: every
                // height measured against the old one is stale.
                let previousMeasurements =
                    self.layoutStore == layoutStore ? self.measurements : [:]
                var changedIDs: Set<String> =
                    self.presentationTheme == presentationTheme
                        && self.layoutStore == layoutStore ? [] : Set(ids)
                var heightInvalidatedIDs = changedIDs
                self.lastMeasuredRowCount = 0
                result.reserveCapacity(ids.count)
                updatedMeasurements.reserveCapacity(ids.count)
                for index in ids.indices {
                    if Task.isCancelled { return }
                    let key =
                        measurementKeys.indices.contains(index) ? measurementKeys[index] : nil
                    let previous = previousMeasurements[ids[index]]
                    let height: CGFloat
                    if let previous, previous.width == width, previous.key == key {
                        height =
                            self.virtualDocument.geometry.index(for: ids[index]).map {
                                self.virtualDocument.geometry.heights[$0]
                            } ?? previous.height
                        if key == nil { changedIDs.insert(ids[index]) }
                    } else {
                        if let preparedHeight = nativeRowHeight?(index, width) {
                            // A lookup in the prepared layouts: nothing
                            // worth giving the frame back for.
                            height = max(1, ceil(preparedHeight))
                        } else {
                            height = max(1, ceil(measure(content(index), width)))
                            await Task.yield()
                        }
                        self.lastMeasuredRowCount += 1
                        changedIDs.insert(ids[index])
                        heightInvalidatedIDs.insert(ids[index])
                    }
                    result.append(height)
                    updatedMeasurements[ids[index]] = Measurement(
                        key: key, width: width, height: height)
                }
                guard !Task.isCancelled else { return }
                self.measurements = updatedMeasurements
                self.presentationTheme = presentationTheme
                self.layoutStore = layoutStore
                self.virtualDocument.nativeRowFactory = nativeRowFactory
                self.virtualDocument.install(
                    heights: result, width: width, ids: ids, changedIDs: changedIDs,
                    heightInvalidatedIDs: heightInvalidatedIDs, content: content)
                onAttach?(self.virtualDocument)
                #if DEBUG
                    ChatBenchmarkAutoRun.trace(
                        "native geometry rows=\(result.count) measured=\(self.lastMeasuredRowCount) width=\(width) totalHeight=\(result.reduce(0,+)) elapsed=\(started.duration(to: .now))"
                    )
                    ChatBenchmarkAutoRun.isNativeGeometryWarm = true
                #endif
            }
        }
    }
}
