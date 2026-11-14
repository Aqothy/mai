import Foundation

/// Hands a transcript document's viewport reports to its receiver at most
/// once per turn of the main actor, only the newest. The receiver changes
/// SwiftUI state, which must not happen inside the layout pass that
/// produced the report.
@MainActor
final class ChatScrollGeometryReporter {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    var onChange: ((ChatScrollGeometry, ChatScrollGeometry) -> Void)?
    private var lastReported: ChatScrollGeometry?
    private var pending: ChatScrollGeometry?
    private(set) var task: Task<Void, Never>?

    func report(_ geometry: ChatScrollGeometry) {
        guard onChange != nil, geometry != (pending ?? lastReported) else { return }
        pending = geometry
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            guard let geometry = self.pending else { return }
            self.pending = nil
            guard geometry != self.lastReported else { return }
            let previous = self.lastReported ?? geometry
            self.lastReported = geometry
            self.onChange?(previous, geometry)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}
