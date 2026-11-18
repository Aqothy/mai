import CoreGraphics
import Foundation
import Synchronization

/// Draws bands' bitmaps on background tasks, nearest to the viewport first,
/// a few at a time, and hands them to their bands on the main thread (PLAN
/// 4.3; the model of Texture's and YYText's async layers). A band changed
/// since its job was queued has a newer generation: a queued job for it is
/// dropped, and a finished one still shows if it is newer than what the band
/// shows (`RowBandLayer.wants`), the current one following.
///
/// A streamed message's jobs are ordered: each bitmap lands only after
/// those submitted before it, so the message's text appears in the order it
/// was written, never a new block before the end of the one above it.
///
/// Finished bitmaps collect in an inbox and are applied together in one
/// main-actor turn, as Texture commits its completions at the end of the
/// run loop: each turn that changes layers costs AppKit a display cycle
/// (layout, tracking areas, a cursor hit test through the window), so one
/// per finished band would cost several per frame.
@MainActor
final class RasterQueue {
    static let shared = RasterQueue()

    private struct Job {
        weak var band: RowBandLayer?
        let generation: Int
        let raster: BandRaster
        /// Distance to the viewport in points: lower runs sooner.
        let priority: CGFloat
        let isOrdered: Bool
    }

    private struct Finished: Sendable {
        let token: Int
        let bitmap: BandBitmap?
    }

    /// Where background tasks leave their bitmaps; the first to arrive in an
    /// empty inbox asks the main actor to drain it.
    private final class Inbox: Sendable {
        let items = Mutex<[Finished]>([])
    }

    private var waiting: [Int: Job] = [:]
    private var running: [Int: Job] = [:]
    /// Ordered bitmaps finished before an earlier ordered job, by token.
    private var held: [Int: (job: Job, bitmap: BandBitmap?)] = [:]
    private var nextToken = 0
    private let concurrency = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
    private let inbox = Inbox()

    func submit(_ band: RowBandLayer, raster: BandRaster, priority: CGFloat, isOrdered: Bool = false) {
        band.pendingGeneration = band.generation
        nextToken += 1
        waiting[nextToken] = Job(
            band: band, generation: band.generation, raster: raster, priority: priority, isOrdered: isOrdered)
        pump()
    }

    private func pump() {
        while running.count < concurrency, let (token, job) = takeNearest() {
            running[token] = job
            let raster = job.raster
            Task.detached(priority: .userInitiated) { [inbox] in
                let finished = Finished(token: token, bitmap: BandRasterizer.bitmap(raster))
                let isFirst = inbox.items.withLock { items in
                    items.append(finished)
                    return items.count == 1
                }
                if isFirst { await RasterQueue.shared.drain() }
            }
        }
    }

    /// The nearest job whose band still wants it, the earliest of equals;
    /// stale ones are dropped.
    private func takeNearest() -> (Int, Job)? {
        dropStaleWaiting()
        guard let nearest = waiting.min(by: { ($0.value.priority, $0.key) < ($1.value.priority, $1.key) }) else {
            return nil
        }
        waiting[nearest.key] = nil
        return (nearest.key, nearest.value)
    }

    private func dropStaleWaiting() {
        waiting = waiting.filter { _, job in job.band.map { $0.generation == job.generation } ?? false }
    }

    /// Applies every bitmap finished since the last drain, in one turn.
    private func drain() {
        let finished = inbox.items.withLock { items in
            defer { items.removeAll(keepingCapacity: true) }
            return items
        }
        for item in finished {
            guard let job = running.removeValue(forKey: item.token) else { continue }
            if job.isOrdered {
                held[item.token] = (job, item.bitmap)
            } else {
                apply(job, item.bitmap)
            }
        }
        if !held.isEmpty {
            dropStaleWaiting()
            var earliest = Int.max
            for (token, job) in waiting where job.isOrdered { earliest = min(earliest, token) }
            for (token, job) in running where job.isOrdered { earliest = min(earliest, token) }
            for token in held.keys.sorted() where token < earliest {
                if let (job, bitmap) = held.removeValue(forKey: token) { apply(job, bitmap) }
            }
        }
        pump()
    }

    private func apply(_ job: Job, _ bitmap: BandBitmap?) {
        guard let band = job.band, band.wants(job.generation) else { return }
        band.show(bitmap, generation: job.generation)
    }
}
