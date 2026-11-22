import CoreGraphics
import Foundation

/// Background layout for one transcript (PLAN 4.2): parses messages, lays
/// rows out, and measures off-screen rows, nearest to the viewport first, on a
/// few tasks at once. Urgent work (the viewport and what scrolls in next)
/// always goes before the background sweep that measures the rest of the
/// history. Results reach the controller as values; Core Text objects never
/// leave the task that made them.
actor LayoutQueue {
    enum Work: Sendable {
        case layout(RowLayoutRequest)
        case measure(RowLayoutRequest)
        case parse(messageID: String, source: String)
        /// Off-screen background sweep: parses a pending message and measures
        /// every resulting block's height in one worker job.
        case parseAndMeasure(messageID: String, source: String, width: CGFloat, style: TextStyle)
    }

    enum Result: Sendable {
        case layout(RowLayout)
        case measured(rowID: String, key: RowLayoutKey, height: CGFloat)
        case parsed(messageID: String, source: String, blocks: [MarkdownBlock])
        case parsedAndMeasured(
            messageID: String, source: String, blocks: [MarkdownBlock], width: CGFloat, styleVersion: Int,
            heights: [CGFloat])

        /// Urgent results (viewport layouts, parses) drain on the next
        /// main-actor turn; background-sweep results coalesce into batches.
        var isUrgent: Bool {
            switch self {
            case .layout, .parsed: true
            case .measured, .parsedAndMeasured: false
            }
        }
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
    private var background: [String: Job] = [:]
    /// Background ids in the order to run them; stale ids are skipped.
    private var backgroundOrder: [String] = []
    private var backgroundCursor = 0
    private var running: Set<String> = []
    private let concurrency: Int
    private let deliver: @Sendable (Result) -> Void

    init(concurrency: Int, deliver: @escaping @Sendable (Result) -> Void) {
        self.concurrency = concurrency
        self.deliver = deliver
    }

    /// Queues work near the viewport. A monotonic `generation` ensures an
    /// out-of-order `replacingUrgent` task can never wipe out a newer window.
    func submit(urgent jobs: [Job], generation: Int = 0, replacingUrgent: Bool) {
        if replacingUrgent {
            if generation > 0, generation < latestUrgentGeneration { return }
            latestUrgentGeneration = max(latestUrgentGeneration, generation)
            urgent.removeAll(keepingCapacity: true)
        }
        for job in jobs {
            urgent[job.id] = job
            background[job.id] = nil
        }
        pump()
    }

    /// Replaces the background sweep: everything else to measure, in order.
    func submit(background jobs: [Job]) {
        background = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        backgroundOrder = jobs.map(\.id)
        backgroundCursor = 0
        pump()
    }

    private func pump() {
        while running.count < concurrency, let job = takeNext() {
            running.insert(job.id)
            let isUrgent = job.priority < Self.backgroundPriority
            Task.detached(priority: isUrgent ? .userInitiated : .utility) { [weak self] in
                let result = Self.perform(job.work)
                await self?.finish(job.id, result)
            }
        }
    }

    static let backgroundPriority = 1_000_000_000

    private func takeNext() -> Job? {
        // A row whose earlier layout still runs waits; its newer job runs next.
        if let job = urgent.values.lazy.filter({ !self.running.contains($0.id) }).min(by: { $0.priority < $1.priority }) {
            urgent[job.id] = nil
            return job
        }
        while backgroundCursor < backgroundOrder.count {
            let id = backgroundOrder[backgroundCursor]
            backgroundCursor += 1
            guard !running.contains(id) else { continue }
            if let job = background.removeValue(forKey: id) { return job }
        }
        if !backgroundOrder.isEmpty {
            backgroundOrder.removeAll()
            backgroundCursor = 0
        }
        return nil
    }

    private func finish(_ id: String, _ result: Result?) {
        running.remove(id)
        if background[id] != nil { backgroundOrder.append(id) }
        if let result { deliver(result) }
        pump()
    }

    private nonisolated static func perform(_ work: Work) -> Result? {
        switch work {
        case .layout(let request):
            return .layout(RowLayoutBuilder.layout(request))
        case .measure(let request):
            return .measured(rowID: request.rowID, key: request.key, height: RowLayoutBuilder.measureHeight(request))
        case .parse(let messageID, let source):
            return .parsed(messageID: messageID, source: source, blocks: MarkdownPlanner.blocks(from: source))
        case .parseAndMeasure(let messageID, let source, let width, let style):
            let blocks = MarkdownPlanner.blocks(from: source)
            let key = RowLayoutKey(contentVersion: 0, width: width, styleVersion: style.version)
            let heights = blocks.indices.map { index in
                RowLayoutBuilder.measureHeight(
                    RowLayoutRequest(
                        rowID: "\(messageID)#\(index)",
                        kind: .markdownBlock(blocks[index], .of(index, in: blocks)),
                        key: key, style: style))
            }
            return .parsedAndMeasured(
                messageID: messageID, source: source, blocks: blocks, width: width, styleVersion: style.version,
                heights: heights)
        }
    }
}
