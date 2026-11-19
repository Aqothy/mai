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
    private var nextToken = 0
    private let concurrency = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
    private let inbox = Inbox()

    func submit(_ band: RowBandLayer, raster: BandRaster, priority: CGFloat) {
        band.pendingGeneration = band.generation
        nextToken += 1
        waiting[nextToken] = Job(band: band, generation: band.generation, raster: raster, priority: priority)
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
        waiting = waiting.filter { _, job in job.band.map { $0.generation == job.generation } ?? false }
        guard let nearest = waiting.min(by: { ($0.value.priority, $0.key) < ($1.value.priority, $1.key) }) else {
            return nil
        }
        waiting[nearest.key] = nil
        return (nearest.key, nearest.value)
    }

    /// Applies every bitmap finished since the last drain, in one turn.
    private func drain() {
        let finished = inbox.items.withLock { items in
            defer { items.removeAll(keepingCapacity: true) }
            return items
        }
        for item in finished {
            guard let job = running.removeValue(forKey: item.token), let band = job.band,
                band.wants(job.generation)
            else { continue }
            band.show(item.bitmap, generation: job.generation)
        }
        pump()
    }
}
