import CoreGraphics
import Foundation
import Synchronization

/// Background layout for one transcript (`REDESIGN.md §4.6, §7 R3`): parses and
/// lays out visible and nearby rows first (`urgent`, `.userInitiated`), then
/// backfills remaining history (`backfill`, nearest-first, `.utility`, 1 worker
/// at a time, yielding immediately while urgent work or active interaction runs)
/// so total document height becomes exact quickly after open while keeping the
/// viewport anchored. Results reach the controller as values; Core Text objects
/// never leave the task that made them.
actor LayoutQueue {
    enum Work: Sendable {
        case layout(RowLayoutRequest, drawing: DrawnBands.Drawing? = nil)
        /// Parses a `.pendingMessage` and lays out all of its blocks in one
        /// worker hop (optionally pre-rastering leading bands for visible rows).
        case parseAndLayout(
            message: TranscriptMessage, source: String, width: CGFloat, style: TextStyle,
            drawing: DrawnBands.Drawing? = nil)
    }

    enum Result: Sendable {
        case layout(RowLayout, drawn: DrawnBands?)
        case parsedAndLaidOut(
            message: TranscriptMessage, source: String, blocks: [MarkdownBlock], metrics: [TextMetrics],
            rows: [TranscriptRow], layouts: [RowLayout], drawn: [DrawnBands?])
    }

    struct Job: Sendable {
        /// One job per id: a newer job replaces a queued one.
        let id: String
        let work: Work
        /// Lower runs sooner: distance to the viewport in points.
        let priority: Int
    }

    private enum WorkKey: Equatable {
        case layout(key: RowLayoutKey, colorsDark: Bool?)
        case parse(message: TranscriptMessage, source: String, width: CGFloat, styleVersion: Int)
    }

    /// Lock-free generation cell checked inside workers before allocating
    /// pre-drawn `IOSurface` bands so stale fling jobs skip wasted rastering.
    private final class GenerationBox: Sendable {
        private let value = Mutex<Int>(0)
        var current: Int {
            get { value.withLock { $0 } }
            set { value.withLock { $0 = newValue } }
        }
    }

    private var urgent: [String: Job] = [:]
    /// Backfill jobs sorted by descending priority so `popLast()` takes the
    /// nearest row in O(1) without O(N) dictionary scans.
    private var backfillStack: [Job] = []
    private var backfillPaused = false
    /// Synchronous pause flag so `MainActor` selection/scroll changes suppress
    /// backfill starts and in-flight deliveries without waiting for an actor hop.
    private let backfillPausedBox = Mutex<Bool>(false)
    private var latestUrgentGeneration = 0
    private let generationBox = GenerationBox()
    /// In-flight jobs keyed by `job.id` with the exact work parameters running,
    /// so duplicate `prefetch` submissions skip re-running identical work while
    /// newer widths/versions still queue behind the in-flight job.
    private var running: [String: WorkKey] = [:]
    private var runningBackfillCount = 0
    private let concurrency: Int
    private let deliver: @Sendable (Result, Bool) -> Void

    init(concurrency: Int, deliver: @escaping @Sendable (Result, Bool) -> Void) {
        self.concurrency = concurrency
        self.deliver = deliver
    }

    nonisolated func markBackfillPaused(_ paused: Bool) {
        backfillPausedBox.withLock { $0 = paused }
    }

    private static func workKey(for work: Work) -> WorkKey {
        switch work {
        case .layout(let request, _):
            .layout(key: request.key, colorsDark: request.codeColors?.isDark)
        case .parseAndLayout(let message, let source, let width, let style, _):
            .parse(message: message, source: source, width: width, styleVersion: style.version)
        }
    }

    /// Queues urgent viewport/prefetch work. A monotonic `generation` ensures
    /// stale out-of-order tasks never overwrite a newer layout window.
    func submit(urgent jobs: [Job], generation: Int, replacingUrgent: Bool) {
        if generation < latestUrgentGeneration { return }
        if generation > latestUrgentGeneration {
            latestUrgentGeneration = generation
            generationBox.current = generation
        }
        if replacingUrgent {
            urgent.removeAll(keepingCapacity: true)
        }
        for job in jobs {
            let key = Self.workKey(for: job.work)
            if running[job.id] == key { continue }
            urgent[job.id] = job
        }
        pump()
    }

    /// Replaces the low-priority exact-geometry backfill queue (called once
    /// after open and after a settled width change, never per frame).
    func setBackfill(_ jobs: [Job], paused: Bool = false) {
        backfillStack = jobs.sorted { $0.priority > $1.priority }
        backfillPaused = paused
        backfillPausedBox.withLock { $0 = paused }
        pump()
    }

    /// Pauses or resumes `.utility` backfill while the reader is actively
    /// scrolling, resizing, or holding a selection.
    func setBackfillPaused(_ paused: Bool) {
        backfillPaused = paused
        backfillPausedBox.withLock { $0 = paused }
        if !paused { pump() }
    }

    /// Cancels all queued work (called when a transcript detaches so
    /// background chats stop burning CPU and memory).
    func cancelAll() {
        latestUrgentGeneration &+= 1
        generationBox.current = latestUrgentGeneration
        urgent.removeAll()
        backfillStack.removeAll()
    }

    private func pump() {
        while running.count < concurrency, let (job, isBackfill) = takeNext() {
            running[job.id] = Self.workKey(for: job.work)
            if isBackfill { runningBackfillCount += 1 }
            let expectedGen = latestUrgentGeneration
            let genBox = generationBox
            let taskPriority: TaskPriority = isBackfill ? .utility : .userInitiated
            Task.detached(priority: taskPriority) { [weak self] in
                let result = Self.perform(job.work, expectedGen: expectedGen, genBox: genBox)
                await self?.finish(job, isBackfill: isBackfill, result)
            }
        }
    }

    private func takeNext() -> (Job, Bool)? {
        // Urgent viewport/prefetch work always runs strictly before backfill.
        if let job = urgent.values.lazy.filter({ self.running[$0.id] == nil }).min(by: { $0.priority < $1.priority }) {
            urgent[job.id] = nil
            return (job, false)
        }
        // Backfill runs at most 1 `.utility` job at a time and yields completely
        // whenever paused or any urgent work is queued or in flight.
        guard !backfillPaused, !backfillPausedBox.withLock({ $0 }), runningBackfillCount == 0, running.isEmpty else {
            return nil
        }
        while let job = backfillStack.popLast() {
            if urgent[job.id] != nil { continue }
            if running[job.id] == Self.workKey(for: job.work) { continue }
            return (job, true)
        }
        return nil
    }

    private func finish(_ job: Job, isBackfill: Bool, _ result: Result) {
        running[job.id] = nil
        if isBackfill { runningBackfillCount = max(0, runningBackfillCount - 1) }
        if isBackfill, backfillPaused || backfillPausedBox.withLock({ $0 }) {
            backfillStack.append(job)
        } else {
            deliver(result, isBackfill)
        }
        pump()
    }

    private nonisolated static func perform(_ work: Work, expectedGen: Int, genBox: GenerationBox) -> Result {
        switch work {
        case .layout(let request, let drawing):
            let layout = RowLayoutBuilder.layout(request)
            let drawn =
                drawing.flatMap { draw in
                    genBox.current == expectedGen ? DrawnBands.drawInitial(layout, drawing: draw, maxBands: 2) : nil
                }
            return .layout(layout, drawn: drawn)
        case .parseAndLayout(let message, let source, let width, let style, let drawing):
            let blocks = MarkdownPlanner.blocks(from: source)
            let rows = message.rows(from: blocks)
            let metrics = rows.map(\.metrics)
            let key = RowLayoutKey(contentVersion: 0, width: width, styleVersion: style.version)
            let layouts = rows.map { row in
                RowLayoutBuilder.layout(
                    RowLayoutRequest(rowID: row.id, kind: row.kind, key: key, style: style))
            }
            var preDrawn: [DrawnBands?] = []
            if let drawing, genBox.current == expectedGen {
                preDrawn.reserveCapacity(layouts.count)
                var remainingBands = 4
                for layout in layouts {
                    guard remainingBands > 0, genBox.current == expectedGen else { break }
                    if let bands = DrawnBands.drawInitial(layout, drawing: drawing, maxBands: 1) {
                        remainingBands -= bands.bands.count + bands.wideBands.count
                        preDrawn.append(bands)
                    } else {
                        preDrawn.append(nil)
                    }
                }
            }
            return .parsedAndLaidOut(
                message: message, source: source, blocks: blocks, metrics: metrics, rows: rows, layouts: layouts,
                drawn: preDrawn)
        }
    }
}
