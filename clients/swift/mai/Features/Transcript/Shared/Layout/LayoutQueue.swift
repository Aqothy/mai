import CoreGraphics
import Foundation

/// Background layout for one transcript (PLAN 4.2): parses messages, lays
/// rows out and highlights code, nearest to the viewport first, on a few
/// tasks at once. Urgent work (the viewport and what scrolls in next) always
/// goes before the background sweep that measures the rest of the history.
/// Results reach the controller as values; Core Text objects never leave the
/// task that made them.
actor LayoutQueue {
    enum Work: Sendable {
        case layout(RowLayoutRequest)
        case highlight(RowLayoutRequest, code: String, language: String?, isDark: Bool)
        case parse(messageID: String, source: String)
    }

    enum Result: Sendable {
        case layout(RowLayout)
        case parsed(messageID: String, source: String, blocks: [MarkdownBlock])
    }

    struct Job: Sendable {
        /// One job per id: a newer job replaces a queued one.
        let id: String
        let work: Work
        /// Lower runs sooner: distance to the viewport in points.
        let priority: Int
    }

    private var urgent: [String: Job] = [:]
    private var background: [String: Job] = [:]
    /// Background ids in the order to run them; stale ids are skipped.
    private var backgroundOrder: [String] = []
    private var backgroundCursor = 0
    private var highlights: [String: Job] = [:]
    private var running: Set<String> = []
    private var isHighlighting = false
    private let concurrency: Int
    private let deliver: @Sendable (Result) -> Void

    init(concurrency: Int, deliver: @escaping @Sendable (Result) -> Void) {
        self.concurrency = concurrency
        self.deliver = deliver
    }

    /// Queues work near the viewport. Earlier urgent jobs not in `jobs` stay
    /// queued but run after these unless `replacingUrgent`.
    func submit(urgent jobs: [Job], replacingUrgent: Bool) {
        if replacingUrgent { urgent.removeAll(keepingCapacity: true) }
        for job in jobs {
            if case .highlight = job.work {
                highlights[job.id] = job
            } else {
                urgent[job.id] = job
                background[job.id] = nil
            }
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
        if !isHighlighting, let job = highlights.values.min(by: { $0.priority < $1.priority }) {
            highlights[job.id] = nil
            isHighlighting = true
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = await Self.highlight(job.work)
                await self?.finishHighlight(result)
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
            if let job = background.removeValue(forKey: id), !running.contains(id) { return job }
        }
        if !backgroundOrder.isEmpty {
            backgroundOrder.removeAll()
            backgroundCursor = 0
        }
        return nil
    }

    private func finish(_ id: String, _ result: Result?) {
        running.remove(id)
        if let result { deliver(result) }
        pump()
    }

    private func finishHighlight(_ result: Result?) {
        isHighlighting = false
        if let result { deliver(result) }
        pump()
    }

    private nonisolated static func perform(_ work: Work) -> Result? {
        switch work {
        case .layout(let request):
            return .layout(RowLayoutBuilder.layout(request))
        case .parse(let messageID, let source):
            return .parsed(messageID: messageID, source: source, blocks: MarkdownPlanner.blocks(from: source))
        case .highlight:
            return nil
        }
    }

    private nonisolated static func highlight(_ work: Work) async -> Result? {
        guard case .highlight(var request, let code, let language, let isDark) = work,
            let colors = await CodeHighlightColors.colors(code: code, language: language, isDark: isDark)
        else { return nil }
        request.codeColors = colors
        request.previousCode = nil
        return .layout(RowLayoutBuilder.layout(request))
    }
}
