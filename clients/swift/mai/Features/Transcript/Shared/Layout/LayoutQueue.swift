import CoreGraphics
import Foundation

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

    enum Work: Sendable {
        case layout(RowLayoutRequest)
        /// Parses a `.pendingMessage` entering the viewport window and, for
        /// small messages, lays out its rows in one worker task.
        case parseAndLayout(message: TranscriptMessage, source: String, width: CGFloat, style: TextStyle)
    }

    enum Result: Sendable {
        case layout(RowLayout)
        case parsedAndLaidOut(
            message: TranscriptMessage, source: String, blocks: [MarkdownBlock], metrics: [TextMetrics],
            layouts: [RowLayout])
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
        if replacingUrgent {
            latestUrgentGeneration = max(latestUrgentGeneration, generation)
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
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = Self.perform(job.work)
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

    private nonisolated static func perform(_ work: Work) -> Result {
        switch work {
        case .layout(let request):
            return .layout(RowLayoutBuilder.layout(request))
        case .parseAndLayout(let message, let source, let width, let style):
            let blocks = MarkdownPlanner.blocks(from: source)
            let rows = message.rows(from: blocks)
            let metrics = rows.map(\.metrics)
            guard source.utf8.count <= eagerParseLayoutByteLimit,
                rows.count <= eagerParseLayoutBlockLimit
            else {
                return .parsedAndLaidOut(
                    message: message, source: source, blocks: blocks, metrics: metrics, layouts: [])
            }
            let key = RowLayoutKey(contentVersion: 0, width: width, styleVersion: style.version)
            let layouts = rows.map { row in
                RowLayoutBuilder.layout(
                    RowLayoutRequest(rowID: row.id, kind: row.kind, key: key, style: style))
            }
            return .parsedAndLaidOut(
                message: message, source: source, blocks: blocks, metrics: metrics, layouts: layouts)
        }
    }
}
