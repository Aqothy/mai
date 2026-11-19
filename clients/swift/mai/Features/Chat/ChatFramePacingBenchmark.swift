#if DEBUG
import OSLog
import QuartzCore
import SwiftUI

#if os(macOS)
    import AppKit

    typealias ChatBenchmarkWindow = NSWindow
    typealias ChatBenchmarkScrollView = NSScrollView
#else
    import UIKit

    typealias ChatBenchmarkWindow = UIWindow
    typealias ChatBenchmarkScrollView = UIScrollView
#endif

/// Display-link callback pacing and main-thread work for one benchmark pass.
///
/// This is a low-overhead regression signal for main-thread stalls while the
/// benchmark drives the transcript. A callback is not proof that the app's
/// surface was presented, so production FPS and hitch claims must come from a
/// bounded Animation Hitches trace rather than these legacy field names.
///
/// Callback pacing is capped by the display: on a 60 Hz display a transcript
/// that needs 2 ms a frame and one that needs 15 ms both report 60. The
/// main-thread fields say how long the main run loop was busy between two
/// callbacks, which is what decides whether a faster display would be kept up
/// with.
nonisolated struct ChatFramePacingReport: Codable, Equatable, Sendable {
    let measurementKind: String
    let label: String
    let displayMaximumFPS: Int
    let frameCount: Int
    let durationSeconds: Double
    let averageFPS: Double
    let expectedFrameMilliseconds: Double
    let p50FrameMilliseconds: Double
    let p95FrameMilliseconds: Double
    let p99FrameMilliseconds: Double
    let maxFrameMilliseconds: Double
    let hitchCount: Int
    let hitchTimeMillisecondsPerSecond: Double
    let p50MainThreadMilliseconds: Double
    let p95MainThreadMilliseconds: Double
    let p99MainThreadMilliseconds: Double
    let maxMainThreadMilliseconds: Double
    /// Frames whose main-thread work alone exceeds one 120 Hz refresh.
    let framesOver120HzBudget: Int
    /// Frames whose main-thread work alone exceeds one 60 Hz refresh.
    let framesOver60HzBudget: Int
    /// The new transcript's rows drawn on screen instead of ahead of it, and
    /// visible rows laid out on the main thread, during the pass (PLAN D3).
    /// Nil for the old transcript.
    var syncFallbackDraws: Int?
    var syncLayouts: Int?
    var arrivalDraws: Int?
    /// Visible rows placed at another height than their layout's (overlap or
    /// gap); 0 when correct.
    var misplacedRows: Int?

    var summary: String {
        """
        \(label) — \(displayMaximumFPS) Hz display
        display-link callbacks: \(frameCount) over \(durationSeconds.formatted(.number.precision(.fractionLength(1))))s · avg \(averageFPS.formatted(.number.precision(.fractionLength(1))))/s
        callback interval ms: p50 \(p50FrameMilliseconds.formatted(.number.precision(.fractionLength(2)))) · p95 \(p95FrameMilliseconds.formatted(.number.precision(.fractionLength(2)))) · p99 \(p99FrameMilliseconds.formatted(.number.precision(.fractionLength(2)))) · max \(maxFrameMilliseconds.formatted(.number.precision(.fractionLength(2)))) (target \(expectedFrameMilliseconds.formatted(.number.precision(.fractionLength(2)))))
        late callbacks: \(hitchCount) · \(hitchTimeMillisecondsPerSecond.formatted(.number.precision(.fractionLength(2)))) excess ms/s
        main-thread work ms per frame: p50 \(p50MainThreadMilliseconds.formatted(.number.precision(.fractionLength(2)))) · p95 \(p95MainThreadMilliseconds.formatted(.number.precision(.fractionLength(2)))) · p99 \(p99MainThreadMilliseconds.formatted(.number.precision(.fractionLength(2)))) · max \(maxMainThreadMilliseconds.formatted(.number.precision(.fractionLength(2)))) · over 8.33 ms: \(framesOver120HzBudget) · over 16.67 ms: \(framesOver60HzBudget)
        """
    }

    var machineReadable: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Records display-link timestamps and main run loop activity while a
/// benchmark runs and reduces them to a report. The link requests the
/// display's maximum refresh rate so main-thread delivery is sampled against
/// the 120 Hz budget.
final class ChatFramePacingMonitor: NSObject {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    private var displayLink: CADisplayLink?
    private var watchdog: Task<Void, Never>?
    private weak var monitoredWindow: ChatBenchmarkWindow?
    private var onFailure: ((String) -> Void)?
    private var timestamps: [CFTimeInterval] = []
    private var onFrame: ((CADisplayLink) -> Void)?
    private var runLoopObserver: CFRunLoopObserver?
    /// When the main run loop last woke; nil while it sleeps.
    private var busySince: CFTimeInterval?
    /// How long the run loop has been awake since the last callback.
    private var busyTime: CFTimeInterval = 0
    private var mainThreadWork: [CFTimeInterval] = []
    private(set) var displayMaximumFPS = 60

    func start(
        in window: ChatBenchmarkWindow?,
        maximumWallSeconds: TimeInterval,
        onFailure: @escaping (String) -> Void,
        onFrame: @escaping (CADisplayLink) -> Void
    ) {
        cancel()
        self.onFailure = onFailure
        monitoredWindow = window
        #if os(macOS)
            guard let window, window.occlusionState.contains(.visible) else {
                onFailure("visible=false before measurement")
                return
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(occlusionChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #endif
        #if os(macOS)
            displayMaximumFPS = window.screen?.maximumFramesPerSecond ?? 60
        #else
            displayMaximumFPS =
                window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        #endif
        self.onFrame = onFrame
        timestamps.removeAll(keepingCapacity: true)
        timestamps.reserveCapacity(displayMaximumFPS * 60)
        mainThreadWork.removeAll(keepingCapacity: true)
        mainThreadWork.reserveCapacity(displayMaximumFPS * 60)

        #if os(macOS)
            guard
                let link = window.screen?.displayLink(
                target: self,
                selector: #selector(tick(_:))
                )
            else { onFailure("no display link available"); return }
        #else
            let link = CADisplayLink(
                target: self,
                selector: #selector(tick(_:))
            )
        #endif
        let rate = Float(displayMaximumFPS)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: rate,
            maximum: rate,
            preferred: rate
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
        observeMainRunLoop()
        watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(maximumWallSeconds)) } catch { return }
            self?.onFailure?("display-link wall-clock timeout")
        }
    }

    #if os(macOS)
        @objc private func occlusionChanged() {
            if monitoredWindow?.occlusionState.contains(.visible) != true {
                onFailure?("visible=false during measurement")
            }
        }
    #endif

    /// The run loop is busy from the moment it wakes until it next sleeps.
    /// It does not sleep between pieces of pending work, so one long stretch
    /// is one busy interval however many sources it served.
    private func observeMainRunLoop() {
        busyTime = 0
        busySince = CACurrentMediaTime()
        let activities: CFRunLoopActivity = [.beforeWaiting, .afterWaiting]
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, activities.rawValue, true, 0
        ) { [weak self] _, activity in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if activity == .afterWaiting {
                self.busySince = now
            } else if let since = self.busySince {
                self.busyTime += now - since
                self.busySince = nil
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        runLoopObserver = observer
    }

    /// Stops recording and reduces the samples. Returns nil for runs too
    /// short to summarize meaningfully.
    func stop(label: String) -> ChatFramePacingReport? {
        cancel()
        defer {
            timestamps.removeAll(keepingCapacity: false)
            mainThreadWork.removeAll(keepingCapacity: false)
        }
        guard timestamps.count >= 10,
            let first = timestamps.first,
            let last = timestamps.last,
            last > first
        else { return nil }

        var intervals: [Double] = []
        intervals.reserveCapacity(timestamps.count - 1)
        for index in 1..<timestamps.count {
            intervals.append(timestamps[index] - timestamps[index - 1])
        }
        intervals.sort()

        let duration = last - first
        let expected = 1.0 / Double(displayMaximumFPS)
        // A callback is late when its delivery misses at least half a refresh
        // interval; the tolerance absorbs normal timer jitter.
        let hitchThreshold = expected * 1.5
        var hitchCount = 0
        var hitchTime = 0.0
        for interval in intervals where interval > hitchThreshold {
            hitchCount += 1
            hitchTime += interval - expected
        }

        func percentile(_ q: Double, of samples: [Double]) -> Double {
            guard !samples.isEmpty else { return 0 }
            return samples[Int(Double(samples.count - 1) * q)] * 1_000
        }

        let work = mainThreadWork.sorted()

        return ChatFramePacingReport(
            measurementKind: "displayLinkCallbacks",
            label: label,
            displayMaximumFPS: displayMaximumFPS,
            frameCount: timestamps.count,
            durationSeconds: duration,
            averageFPS: Double(intervals.count) / duration,
            expectedFrameMilliseconds: expected * 1_000,
            p50FrameMilliseconds: percentile(0.5, of: intervals),
            p95FrameMilliseconds: percentile(0.95, of: intervals),
            p99FrameMilliseconds: percentile(0.99, of: intervals),
            maxFrameMilliseconds: (intervals.last ?? 0) * 1_000,
            hitchCount: hitchCount,
            hitchTimeMillisecondsPerSecond: hitchTime * 1_000 / duration,
            p50MainThreadMilliseconds: percentile(0.5, of: work),
            p95MainThreadMilliseconds: percentile(0.95, of: work),
            p99MainThreadMilliseconds: percentile(0.99, of: work),
            maxMainThreadMilliseconds: (work.last ?? 0) * 1_000,
            framesOver120HzBudget: work.count { $0 > 1.0 / 120 },
            framesOver60HzBudget: work.count { $0 > 1.0 / 60 }
        )
    }

    func cancel() {
        watchdog?.cancel()
        watchdog = nil
        #if os(macOS)
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeOcclusionStateNotification, object: monitoredWindow)
        #endif
        monitoredWindow = nil
        onFailure = nil
        displayLink?.invalidate()
        displayLink = nil
        if let runLoopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), runLoopObserver, .commonModes)
        }
        runLoopObserver = nil
        onFrame = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        // The callback itself runs inside a busy stretch; close it here so
        // each sample is the work between two callbacks.
        let now = CACurrentMediaTime()
        if let since = busySince {
            busyTime += now - since
            busySince = now
        }
        if !timestamps.isEmpty {
            mainThreadWork.append(busyTime)
        }
        busyTime = 0
        timestamps.append(link.timestamp)
        onFrame?(link)
    }
}

/// Runs frame-pacing benchmarks against the live chat surface: a constant
/// velocity scroll sweep that realizes rows exactly like a user flick, and a
/// passive monitor for streaming runs. Results are logged for headless
/// harvesting.
@Observable
final class ChatBenchmarkModel {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    private static let logger = Logger(
        subsystem: "com.aqothy.mai",
        category: "ChatBenchmark"
    )

    private(set) var isRunning = false
    @ObservationIgnored private var fallbackDrawsAtStart = 0
    @ObservationIgnored private var syncLayoutsAtStart = 0
    @ObservationIgnored private var arrivalDrawsAtStart = 0
    @ObservationIgnored private var misplacedRowsAtStart = 0

    private func noteStart(_ label: String) {
        fallbackDrawsAtStart = TranscriptDebugCounters.syncFallbackDraws
        syncLayoutsAtStart = TranscriptDebugCounters.syncLayouts
        arrivalDrawsAtStart = TranscriptDebugCounters.arrivalDraws
        misplacedRowsAtStart = TranscriptDebugCounters.misplacedRows
        Self.note("benchmark start: \(label)")
    }

    private static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        ChatBenchmarkAutoRun.trace(message)
    }

    /// Sweeps the transcript up and then back down at a constant velocity,
    /// like a sustained fast flick, while recording frame pacing.
    func runScrollBenchmark(
        pointsPerSecond: CGFloat,
        maximumSweepSeconds: TimeInterval,
        label: String
    ) async -> ChatFramePacingReport? {
        guard !isRunning else {
            Self.note("benchmark skipped: already running")
            return nil
        }
        guard let window = Self.appWindow() else {
            Self.note("benchmark skipped: no window")
            return nil
        }
        guard let scrollView = Self.transcriptScrollView(in: window) else {
            Self.note("benchmark skipped: no transcript scroll view")
            return nil
        }
        #if os(macOS)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
        #endif
        noteStart(label)
        isRunning = true
        defer { isRunning = false }

        let document = Self.transcriptDocument(of: scrollView)
        let anchorRow = UserDefaults.standard.integer(forKey: "ChatBenchmarkAnchorRow")
        if anchorRow > 0 {
            let horizontalOrigin = Self.contentOffsetX(of: scrollView)
            document?.scrollToBenchmarkRow(anchorRow)
            try? await Task.sleep(for: .milliseconds(250))
            guard abs(Self.contentOffsetX(of: scrollView) - horizontalOrigin) < 0.5 else {
                Self.note("invalid measurement: benchmark anchor changed horizontal alignment")
                return nil
            }
            Self.note(
                "anchor row=\(anchorRow) x=\(horizontalOrigin) preservedX=true offset=\(Self.contentOffsetY(of: scrollView)) range=\(Self.scrollableRange(of: scrollView))"
            )
        }
        // The anchor jump lands somewhere unseen on purpose; only the sweep
        // after it counts toward rows drawn on screen instead of ahead.
        fallbackDrawsAtStart = TranscriptDebugCounters.syncFallbackDraws
        syncLayoutsAtStart = TranscriptDebugCounters.syncLayouts
        arrivalDrawsAtStart = TranscriptDebugCounters.arrivalDraws
        misplacedRowsAtStart = TranscriptDebugCounters.misplacedRows
        let monitor = ChatFramePacingMonitor()
        var scrollsUpward = true
        let scrubPeriod = UserDefaults.standard.double(forKey: "ChatBenchmarkScrubPeriod")
        var scrubStarted: CFTimeInterval?
        var offsetY = Self.contentOffsetY(of: scrollView)
        var lastTimestamp: CFTimeInterval?
        var phaseStartTimestamp: CFTimeInterval?
        var finished = false
        var encounteredOcclusion = false

        await withCheckedContinuation { continuation in
            monitor.start(
                in: window, maximumWallSeconds: maximumSweepSeconds * 2 + 15,
                onFailure: { reason in
                guard !finished else { return }
                    finished = true
                    Self.note("invalid measurement: \(reason)")
                    continuation.resume()
                }
            ) { link in
                guard !finished else { return }
                if !Self.isWindowVisible(window) { encounteredOcclusion = true }
                let timestamp = link.timestamp
                let elapsed = timestamp - (lastTimestamp ?? timestamp)
                lastTimestamp = timestamp
                phaseStartTimestamp = phaseStartTimestamp ?? timestamp

                if elapsed > 0.1 {
                    // An occluded window pauses the display link; that gap is
                    // not a main-thread stall and must be read as such.
                    Self.note(
                        "stall \(Int(elapsed * 1_000)) ms at offset \(Int(offsetY)) visible=\(Self.isWindowVisible(window))"
                    )
                }
                let (minY, maxY) = Self.scrollableRange(of: scrollView)
                if scrubPeriod > 0 {
                    scrubStarted = scrubStarted ?? timestamp
                    let phase = ((timestamp - (scrubStarted ?? timestamp)) / scrubPeriod)
                        .truncatingRemainder(dividingBy: 2)
                    let fraction = phase <= 1 ? 1 - phase : phase - 1
                    offsetY = minY + (maxY - minY) * fraction
                } else {
                    offsetY += (scrollsUpward ? -1 : 1) * pointsPerSecond * elapsed
                    offsetY = min(max(offsetY, minY), maxY)
                }
                Self.setContentOffsetY(offsetY, on: scrollView)

                let phaseElapsed = timestamp - (phaseStartTimestamp ?? timestamp)
                let reachedEnd = scrollsUpward ? offsetY <= minY : offsetY >= maxY
                if (scrubPeriod <= 0 && reachedEnd) || phaseElapsed >= maximumSweepSeconds {
                    if scrollsUpward {
                        scrollsUpward = false
                        phaseStartTimestamp = timestamp
                    } else {
                        finished = true
                        continuation.resume()
                    }
                }
            }
        }
        if encounteredOcclusion { Self.note("invalid measurement: visible=false during sweep") }
        if let document {
            Self.note(document.benchmarkStatistics)
        }
        let measuredLabel =
            scrubPeriod > 0
            ? "full-history-scrub-\(scrubPeriod)s-\(maximumSweepSeconds * 2)s" : label
        return finish(monitor, label: measuredLabel)
    }

    #if os(macOS)
        func reportOpenBenchmark(started: ContinuousClock.Instant) {
            let elapsed = started.duration(to: .now).components
            let window = Self.appWindow()
            let scroll = window.flatMap { Self.transcriptScrollView(in: $0) }
            let rows = (scroll?.documentView as? any ChatBenchmarkRowGeometry)?.numberOfRows ?? 0
            let report: [String: Any] = [
                "label": "prepared-aligned-transcript",
                "measurementKind": "preparedAlignedViewport",
                "readyMilliseconds": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds)
                    / 1e15,
                "loadedRows": rows,
                "aligned": ChatBenchmarkAutoRun.isInitialAlignmentComplete,
                "visible": window.map(Self.isWindowVisible) ?? false,
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: report, options: [.sortedKeys]),
                let json = String(data: data, encoding: .utf8)
            {
                print("CHAT_BENCHMARK_RESULT \(json)")
            }
        }
    #endif

    #if os(macOS)
        /// Narrows the window from its pinned width to `minimumWidth` and back
        /// over `seconds`, one step per display frame, while recording frame
        /// pacing: the transcript reflows below its content cap. A scripted
        /// resize is not AppKit live resize (no `inLiveResize`), so a
        /// transcript that waits for the end of live resize sees every step
        /// as a width change.
        func runResizeBenchmark(
            in window: NSWindow, minimumWidth: CGFloat, seconds: TimeInterval, label: String
        ) async -> ChatFramePacingReport? {
            guard !isRunning else { return nil }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            noteStart(label)
            isRunning = true
            defer { isRunning = false }
            let startSize = window.contentRect(forFrameRect: window.frame).size
            window.contentMinSize = NSSize(width: minimumWidth, height: startSize.height)
            window.contentMaxSize = startSize
            let monitor = ChatFramePacingMonitor()
            var started: CFTimeInterval?
            var finished = false
            var encounteredOcclusion = false
            // Frames showing some visible row at an older width, and the
            // longest run of them: how far reflow trails the window edge.
            var staleFrames = 0
            var staleRun = 0
            var longestStaleRun = 0
            // Frames whose text trails the column by more than 16 points (a
            // visible reflow lag, not one frame behind), and the longest run.
            var laggingFrames = 0
            var lagRun = 0
            var longestLagRun = 0
            var lagSum: CGFloat = 0
            var frames = 0
            await withCheckedContinuation { continuation in
                monitor.start(
                    in: window, maximumWallSeconds: seconds + 15,
                    onFailure: { reason in
                        guard !finished else { return }
                        finished = true
                        Self.note("invalid measurement: \(reason)")
                        continuation.resume()
                    }
                ) { link in
                    guard !finished else { return }
                    if !Self.isWindowVisible(window) { encounteredOcclusion = true }
                    if started != nil {
                        frames += 1
                        if TranscriptDebugCounters.staleVisibleRows > 0 {
                            staleFrames += 1
                            staleRun += 1
                            longestStaleRun = max(longestStaleRun, staleRun)
                        } else {
                            staleRun = 0
                        }
                        let lag = TranscriptDebugCounters.visibleWidthLag
                        lagSum += lag
                        if lag > 16 {
                            laggingFrames += 1
                            lagRun += 1
                            longestLagRun = max(longestLagRun, lagRun)
                        } else {
                            lagRun = 0
                        }
                    }
                    started = started ?? link.timestamp
                    let progress = (link.timestamp - (started ?? link.timestamp)) / seconds
                    let fraction = progress <= 0.5 ? progress * 2 : max(0, 2 - progress * 2)
                    let width = (startSize.width - (startSize.width - minimumWidth) * fraction)
                        .rounded()
                    window.setContentSize(NSSize(width: width, height: startSize.height))
                    if progress >= 1 {
                        finished = true
                        continuation.resume()
                    }
                }
            }
            window.setContentSize(startSize)
            if TranscriptEngine.isNewEngineEnabled {
                ChatBenchmarkAutoRun.trace(
                    "resize reflow staleFrames=\(staleFrames) of \(frames) longestStaleRun=\(longestStaleRun)"
                        + " laggingFrames=\(laggingFrames) longestLagRun=\(longestLagRun)"
                        + " meanLag=\(Int(lagSum / CGFloat(max(1, frames))))")
            }
            if encounteredOcclusion { Self.note("invalid measurement: visible=false during resize") }
            return finish(monitor, label: label)
        }
    #endif

    /// Records frame pacing while something else (a streaming reply) drives
    /// the content, until `isDone` reports completion or the cap elapses.
    func runStreamingBenchmark(
        label: String,
        maximumSeconds: TimeInterval,
        isDone: @escaping () -> Bool
    ) async -> ChatFramePacingReport? {
        guard !isRunning, let window = Self.appWindow() else {
            Self.note(
                "benchmark skipped: \(isRunning ? "already running" : "no window")"
            )
            return nil
        }
        #if os(macOS)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
        #endif
        noteStart(label)
        isRunning = true
        defer { isRunning = false }

        let monitor = ChatFramePacingMonitor()
        var startTimestamp: CFTimeInterval?
        var finished = false
        var encounteredOcclusion = false

        await withCheckedContinuation { continuation in
            monitor.start(
                in: window, maximumWallSeconds: maximumSeconds + 15,
                onFailure: { reason in
                guard !finished else { return }
                    finished = true
                    Self.note("invalid measurement: \(reason)")
                    continuation.resume()
                }
            ) { link in
                guard !finished else { return }
                if !Self.isWindowVisible(window) { encounteredOcclusion = true }
                startTimestamp = startTimestamp ?? link.timestamp
                let elapsed = link.timestamp - (startTimestamp ?? link.timestamp)
                if isDone() || elapsed >= maximumSeconds {
                    finished = true
                    continuation.resume()
                }
            }
        }
        if encounteredOcclusion { Self.note("invalid measurement: visible=false during stream") }
        return finish(monitor, label: label)
    }

    private func finish(
        _ monitor: ChatFramePacingMonitor,
        label: String
    ) -> ChatFramePacingReport? {
        guard var report = monitor.stop(label: label) else { return nil }
        if TranscriptEngine.isNewEngineEnabled {
            report.syncFallbackDraws = TranscriptDebugCounters.syncFallbackDraws - fallbackDrawsAtStart
            report.syncLayouts = TranscriptDebugCounters.syncLayouts - syncLayoutsAtStart
            report.arrivalDraws = TranscriptDebugCounters.arrivalDraws - arrivalDrawsAtStart
            report.misplacedRows = TranscriptDebugCounters.misplacedRows - misplacedRowsAtStart
        }
        Self.logger.notice("\(report.summary, privacy: .public)")
        Self.logger.notice(
            "CHAT_BENCHMARK_RESULT \(report.machineReadable, privacy: .public)"
        )
        ChatBenchmarkAutoRun.trace(
            "CHAT_BENCHMARK_RESULT \(report.machineReadable)"
        )
        print("CHAT_BENCHMARK_RESULT \(report.machineReadable)")
        return report
    }

    private static func isWindowVisible(_ window: ChatBenchmarkWindow) -> Bool {
        #if os(macOS)
            window.occlusionState.contains(.visible)
        #else
            !window.isHidden
        #endif
    }

    /// A headless launch may start measuring before any window becomes key.
    static func appWindow() -> ChatBenchmarkWindow? {
        #if os(macOS)
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
        #else
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            return windows.first { $0.isKeyWindow } ?? windows.first
        #endif
    }

    /// The transcript's vertical scroller is the deepest scroll view with the
    /// tallest content; text views and horizontal code scrollers never win.
    static func transcriptScrollView(
        in window: ChatBenchmarkWindow
    ) -> ChatBenchmarkScrollView? {
        #if os(macOS)
            guard let contentView = window.contentView else { return nil }
            var best: NSScrollView?
            var queue: [NSView] = [contentView]
            while let view = queue.popLast() {
                queue.append(contentsOf: view.subviews)
                guard let scrollView = view as? NSScrollView,
                    !(scrollView.documentView is NSTextView),
                    let documentView = scrollView.documentView,
                    documentView.bounds.height > scrollView.contentView.bounds.height
                else { continue }
                if documentView.bounds.height
                    > (best?.documentView?.bounds.height ?? 0)
                {
                    best = scrollView
                }
            }
            return best
        #else
            var best: UIScrollView?
            var queue: [UIView] = [window]
            while let view = queue.popLast() {
                queue.append(contentsOf: view.subviews)
                guard let scrollView = view as? UIScrollView,
                    !(scrollView is UITextView),
                    scrollView.contentSize.height > scrollView.bounds.height
                else { continue }
                if scrollView.contentSize.height
                    > (best?.contentSize.height ?? 0)
                {
                    best = scrollView
                }
            }
            return best
        #endif
    }

    private static func transcriptDocument(
        of scrollView: ChatBenchmarkScrollView
    ) -> (any ChatBenchmarkAnchoredDocument)? {
        #if os(macOS)
            scrollView.documentView as? any ChatBenchmarkAnchoredDocument
        #else
            scrollView as? any ChatBenchmarkAnchoredDocument
        #endif
    }

    private static func contentOffsetX(
        of scrollView: ChatBenchmarkScrollView
    ) -> CGFloat {
        #if os(macOS)
            scrollView.contentView.bounds.origin.x
        #else
            scrollView.contentOffset.x
        #endif
    }

    private static func contentOffsetY(
        of scrollView: ChatBenchmarkScrollView
    ) -> CGFloat {
        #if os(macOS)
            scrollView.contentView.bounds.origin.y
        #else
            scrollView.contentOffset.y
        #endif
    }

    private static func scrollableRange(
        of scrollView: ChatBenchmarkScrollView
    ) -> (minY: CGFloat, maxY: CGFloat) {
        #if os(macOS)
            guard let documentView = scrollView.documentView else {
                let offset = scrollView.contentView.bounds.origin.y
                return (offset, offset)
            }
            let minY = documentView.bounds.minY
            let maxY = max(
                minY,
                documentView.bounds.maxY - scrollView.contentView.bounds.height
            )
            return (minY, maxY)
        #else
            let minY = -scrollView.adjustedContentInset.top
            let maxY = max(
                minY,
                scrollView.contentSize.height
                    + scrollView.adjustedContentInset.bottom
                    - scrollView.bounds.height
            )
            return (minY, maxY)
        #endif
    }

    static func setContentOffsetY(
        _ offsetY: CGFloat,
        on scrollView: ChatBenchmarkScrollView
    ) {
        #if os(macOS)
            let clipView = scrollView.contentView
            clipView.scroll(
                to: NSPoint(x: clipView.bounds.origin.x, y: offsetY)
            )
            scrollView.reflectScrolledClipView(clipView)
        #else
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: offsetY),
                animated: false
            )
        #endif
    }
}

/// Headless benchmarking: launching a Debug build with
/// `-ChatAutoBenchmark <plan>` with a benchmark thread runs the selected
/// passes against the production timeline, printing one `CHAT_BENCHMARK_RESULT` JSON line per
/// pass and `CHAT_BENCHMARK_COMPLETE` at the end.
nonisolated enum ChatBenchmarkAutoRun {
    static let logger = Logger(
        subsystem: "com.aqothy.mai",
        category: "ChatBenchmark"
    )

    static var plan: String? {
        UserDefaults.standard.string(forKey: "ChatAutoBenchmark")
    }

    /// `-ChatBenchmarkThread <title substring>` benchmarks a real thread from
    /// the connected daemon. A synthetic transcript (below) is selected the
    /// same way, by its fixed title.
    static var threadTitleQuery: String? {
        if let value = UserDefaults.standard.string(
            forKey: "ChatBenchmarkThread"
        )?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            return value
        }
        return syntheticThreadTurnCount != nil ? ChatSyntheticBenchmarkThread.title : nil
    }

    /// `-ChatBenchmarkSyntheticTurns <n>` seeds the store with a generated
    /// `n`-turn transcript and benchmarks the production timeline without
    /// a daemon. Zero or a missing value leaves the real store in place.
    static var syntheticThreadTurnCount: Int? {
        let turns = UserDefaults.standard.integer(forKey: "ChatBenchmarkSyntheticTurns")
        return turns > 0 ? turns : nil
    }

    /// Whether the timeline has finished priming caches and layouts for the whole
    /// loaded transcript. The scroll benchmark waits for this so it measures
    /// the production steady state — production always prepares a page off
    /// the main actor before inserting it into the timeline.
    @MainActor static var isTranscriptWarm = false
    @MainActor static var isNativeGeometryWarm = false
    @MainActor static var isInitialAlignmentComplete = false

    /// A window resize while priming restarts the warm at the new width;
    /// the benchmark must keep waiting for the latest pass.
    @MainActor static func noteTranscriptWarmStarted() {
        isTranscriptWarm = false
        trace("transcript warm started")
    }

    @MainActor static func noteTranscriptWarm() {
        isTranscriptWarm = true
        trace("transcript warm")
    }

    @MainActor static func awaitTranscriptWarm(
        timeoutSeconds: TimeInterval
    ) async {
        // The native transcript must also have installed its row geometry.
        func isWarm() -> Bool { isTranscriptWarm && isNativeGeometryWarm }
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while !isWarm(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if !isWarm() {
            trace("transcript warm timed out")
        }
    }

    /// A harness tails stdout to time profilers against benchmark phases;
    /// block buffering would delay those lines by kilobytes of output.
    private static let lineBufferedStandardOutput: Void = {
        setvbuf(stdout, nil, _IOLBF, 0)
    }()

    /// Opened once for the process: opening, seeking and closing a handle per
    /// line cost the streaming benchmark ~2 % of its main thread.
    private static let traceFile: FileHandle? = {
        let url = URL(fileURLWithPath: "/tmp/mai-chat-benchmark.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    /// Headless runs append results to a file and echo them to stdout: a
    /// sandboxed build cannot write outside its container, stdout is lost
    /// under `open`, and ad-hoc launched builds may not reach the unified log.
    static func trace(_ message: String) {
        guard plan != nil else { return }
        _ = lineBufferedStandardOutput
        print("CHAT_BENCHMARK_TRACE \(message)")
        try? traceFile?.write(contentsOf: Data((message + "\n").utf8))
    }

    /// `-ChatBenchmarkTranscriptOnly NO` keeps the sidebar, composer and
    /// toolbar in a benchmark run; by default a run shows the transcript
    /// alone so its numbers measure the chat and nothing else.
    static var isTranscriptOnly: Bool {
        guard plan != nil else { return false }
        guard UserDefaults.standard.object(forKey: "ChatBenchmarkTranscriptOnly") != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: "ChatBenchmarkTranscriptOnly")
    }
}

@MainActor protocol ChatBenchmarkAnchoredDocument {
    func scrollToBenchmarkRow(_ index: Int)
    var benchmarkStatistics: String { get }
}

extension ChatNativeTranscript.VirtualDocument: ChatBenchmarkAnchoredDocument {
    func scrollToBenchmarkRow(_ index: Int) {
        #if os(macOS)
            guard index >= 0, index < offsets.count - 1, let scroll = enclosingScrollView
            else { return }
            ChatBenchmarkModel.setContentOffsetY(offsets[index], on: scroll)
        #else
            guard index >= 0, index < numberOfRows else { return }
            ChatBenchmarkModel.setContentOffsetY(
                offsets[index] - adjustedContentInset.top, on: self)
        #endif
    }

    var benchmarkStatistics: String {
        "nativeMounts=\(nativeMounts) hostingMounts=\(hostingMounts) created=\(createdRows) resident=\(hosts.count) pooled=\(reusableNative.count + reusableHosting.count)"
    }
}
#endif
