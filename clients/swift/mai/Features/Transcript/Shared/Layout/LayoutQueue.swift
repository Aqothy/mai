import CoreGraphics
import Foundation
import Synchronization

/// Background layout for one transcript (PLAN 4.2): parses and lays out rows
/// near the viewport, nearest first, on a few tasks at once. Off-screen history
/// stays estimated until scrolled near (same on-demand model as Zed GPUI,
/// Chrome `content-visibility: auto`, Texture, and Telegram). Results reach the
/// controller as values; Core Text objects never leave the task that made them.
actor LayoutQueue {
    /// Messages at or below both limits are parsed and laid out in one worker
    /// hop (zero extra main-actor round-trip). Larger messages parse only,
    /// splice with estimated heights, and let the viewport window lay out only
    /// visible and nearby rows.
    static let eagerParseLayoutByteLimit = 16_384
    static let eagerParseLayoutBlockLimit = 32

    private final class GenerationBox: Sendable {
        let value = Mutex<Int>(0)
    }

    enum Work: Sendable {
        case layout(RowLayoutRequest, drawing: DrawnBands.Drawing? = nil)
        /// Parses a `.pendingMessage` entering the viewport window and, for
        /// small messages, lays out (and optionally pre-rasters) its rows in
        /// one worker task.
        case parseAndLayout(
            message: TranscriptMessage, source: String, width: CGFloat, style: TextStyle,
            drawing: DrawnBands.Drawing? = nil)
    }

    enum Result: Sendable {
        case layout(RowLayout, drawn: DrawnBands?)
        case parsedAndLaidOut(
            message: TranscriptMessage, source: String, blocks: [MarkdownBlock], metrics: [TextMetrics],
            layouts: [RowLayout], drawn: [DrawnBands?])
    }

    struct Job: Sendable {
        /// One job per id: a newer job replaces a queued one.
        let id: String
        let work: Work
        /// Lower runs sooner: distance to the viewport in points.
        let priority: Int
    }

    private var urgent: [String: Job] = [:]
    private var latestUrgentGeneration = 0
    private let activeGeneration = GenerationBox()
    private var running: Set<String> = []
    private let concurrency: Int
    private let deliver: @Sendable (Result) -> Void

    init(concurrency: Int, deliver: @escaping @Sendable (Result) -> Void) {
        self.concurrency = concurrency
        self.deliver = deliver
    }

    /// Queues work near the viewport. A monotonic `generation` ensures stale
    /// out-of-order tasks (whether `replacingUrgent` or `prefetch`) can never
    /// overwrite a newer layout window.
    func submit(urgent jobs: [Job], generation: Int, replacingUrgent: Bool) {
        if generation < latestUrgentGeneration { return }
        if generation > latestUrgentGeneration {
            latestUrgentGeneration = generation
            activeGeneration.value.withLock { $0 = generation }
        }
        if replacingUrgent {
            urgent.removeAll(keepingCapacity: true)
        }
        for job in jobs {
            urgent[job.id] = job
        }
        pump()
    }

    private func pump() {
        while running.count < concurrency, let job = takeNext() {
            running.insert(job.id)
            let expectedGeneration = latestUrgentGeneration
            let generationBox = activeGeneration
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = Self.perform(
                    job.work, expectedGeneration: expectedGeneration, activeGeneration: generationBox)
                await self?.finish(job.id, result)
            }
        }
    }

    private func takeNext() -> Job? {
        // A row whose earlier layout still runs waits; its newer job runs next.
        if let job = urgent.values.lazy.filter({ !self.running.contains($0.id) }).min(by: { $0.priority < $1.priority }) {
            urgent[job.id] = nil
            return job
        }
        return nil
    }

    private func finish(_ id: String, _ result: Result) {
        running.remove(id)
        deliver(result)
        pump()
    }

    private nonisolated static func isCurrentGeneration(_ expected: Int, box: GenerationBox) -> Bool {
        box.value.withLock { $0 } == expected
    }

    private nonisolated static func perform(
        _ work: Work, expectedGeneration: Int, activeGeneration: GenerationBox
    ) -> Result {
        switch work {
        case .layout(let request, let drawing):
            let layout = RowLayoutBuilder.layout(request)
            // Skip speculative 1-hop pre-raster if the viewport already moved on
            // (eliminates wasted glyph painting during fast scrolling).
            let drawn: DrawnBands? =
                if let drawing, isCurrentGeneration(expectedGeneration, box: activeGeneration) {
                    DrawnBands.drawInitial(layout, drawing: drawing, maxBands: 2)
                } else {
                    nil
                }
            return .layout(layout, drawn: drawn)
        case .parseAndLayout(let message, let source, let width, let style, let drawing):
            let blocks = MarkdownPlanner.blocks(from: source)
            let rows = message.rows(from: blocks)
            let metrics = rows.map(\.metrics)
            guard source.utf8.count <= eagerParseLayoutByteLimit,
                rows.count <= eagerParseLayoutBlockLimit
            else {
                return .parsedAndLaidOut(
                    message: message, source: source, blocks: blocks, metrics: metrics, layouts: [], drawn: [])
            }
            let key = RowLayoutKey(contentVersion: 0, width: width, styleVersion: style.version)
            let layouts = rows.map { row in
                RowLayoutBuilder.layout(
                    RowLayoutRequest(rowID: row.id, kind: row.kind, key: key, style: style))
            }
            var preDrawn: [DrawnBands?] = []
            if let drawing, isCurrentGeneration(expectedGeneration, box: activeGeneration) {
                preDrawn.reserveCapacity(layouts.count)
                var remainingBands = 4
                for layout in layouts {
                    if remainingBands > 0, isCurrentGeneration(expectedGeneration, box: activeGeneration),
                        let bands = DrawnBands.drawInitial(layout, drawing: drawing, maxBands: 1)
                    {
                        remainingBands -= bands.bands.count + bands.wideBands.count
                        preDrawn.append(bands)
                    } else {
                        preDrawn.append(nil)
                    }
                }
            }
            return .parsedAndLaidOut(
                message: message, source: source, blocks: blocks, metrics: metrics, layouts: layouts, drawn: preDrawn)
        }
    }
}
