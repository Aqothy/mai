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
        /// Rows a pass measured before a newer update cancelled it. A pass
        /// yields after each SwiftUI row it sizes, and updates can arrive
        /// faster than a whole pass; without these, each pass would start
        /// over and the rows would never install.
        private var unpublishedMeasurements: [String: Measurement] = [:]
        private var unpublishedLayoutStore: ObjectIdentifier?
        private var presentationTheme: ChatCodeHighlightTheme?
        private var layoutStore: ObjectIdentifier?
        private(set) var lastMeasuredRowCount = 0

        func update(
            ids: [String], sourceIDs: [String] = [], width: CGFloat, measurementKeys: [ChatNativeRowMeasurementKey?] = [],
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
                unpublishedMeasurements.removeAll()
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
                if self.unpublishedLayoutStore != layoutStore {
                    self.unpublishedMeasurements.removeAll()
                    self.unpublishedLayoutStore = layoutStore
                }
                // Rows not measured again take their height at install: a
                // mounted row can report a new one while this pass yields.
                var unmeasured: [Int] = []
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
                        height = previous.height
                        unmeasured.append(index)
                        if key == nil { changedIDs.insert(ids[index]) }
                    } else {
                        let unpublished = self.unpublishedMeasurements[ids[index]]
                        if let preparedHeight = nativeRowHeight?(index, width) {
                            // A lookup in the prepared layouts: nothing
                            // worth giving the frame back for.
                            height = max(1, ceil(preparedHeight))
                        } else if let unpublished, unpublished.width == width,
                            unpublished.key == key
                        {
                            height = unpublished.height
                        } else {
                            height = max(1, ceil(measure(content(index), width)))
                            self.unpublishedMeasurements[ids[index]] = Measurement(
                                key: key, width: width, height: height)
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
                let geometry = self.virtualDocument.geometry
                for index in unmeasured {
                    guard let current = geometry.index(for: ids[index]) else { continue }
                    result[index] = geometry.heights[current]
                    updatedMeasurements[ids[index]] = Measurement(
                        key: measurementKeys.indices.contains(index) ? measurementKeys[index] : nil,
                        width: width, height: result[index])
                }
                self.measurements = updatedMeasurements
                self.unpublishedMeasurements.removeAll()
                self.presentationTheme = presentationTheme
                self.layoutStore = layoutStore
                self.virtualDocument.nativeRowFactory = nativeRowFactory
                self.virtualDocument.install(
                    heights: result, width: width, ids: ids, sourceIDs: sourceIDs,
                    changedIDs: changedIDs,
                    heightInvalidatedIDs: heightInvalidatedIDs, content: content)
                onAttach?(self.virtualDocument)
                #if DEBUG
                    ChatBenchmarkAutoRun.trace(
                        "native geometry rows=\(result.count) measured=\(self.lastMeasuredRowCount) width=\(width) totalHeight=\(result.reduce(0, +)) elapsed=\(started.duration(to: .now))"
                    )
                    ChatBenchmarkAutoRun.isNativeGeometryWarm = true
                #endif
            }
        }
    }
}
