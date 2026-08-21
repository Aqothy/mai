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

/// Measured frame pacing for one benchmark pass.
///
/// `hitchTimeMillisecondsPerSecond` follows Apple's hitch-ratio metric: the
/// total time frames arrived late, normalized per second of the run. Values
/// under 5 ms/s are considered smooth; under 1 ms/s is effectively perfect.
nonisolated struct ChatFramePacingReport: Codable, Equatable, Sendable {
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

    var summary: String {
        """
        \(label) — \(displayMaximumFPS) Hz display
        frames: \(frameCount) over \(durationSeconds.formatted(.number.precision(.fractionLength(1))))s · avg \(averageFPS.formatted(.number.precision(.fractionLength(1)))) fps
        frame ms: p50 \(p50FrameMilliseconds.formatted(.number.precision(.fractionLength(2)))) · p95 \(p95FrameMilliseconds.formatted(.number.precision(.fractionLength(2)))) · p99 \(p99FrameMilliseconds.formatted(.number.precision(.fractionLength(2)))) · max \(maxFrameMilliseconds.formatted(.number.precision(.fractionLength(2)))) (budget \(expectedFrameMilliseconds.formatted(.number.precision(.fractionLength(2)))))
        hitches: \(hitchCount) · \(hitchTimeMillisecondsPerSecond.formatted(.number.precision(.fractionLength(2)))) ms/s
        """
    }

    var machineReadable: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Records display-link timestamps while a benchmark runs and reduces them to
/// a frame-pacing report. The link requests the display's maximum refresh
/// rate so an adaptive-sync (ProMotion) display is measured at 120 Hz rather
/// than whatever idle rate it happens to be running.
final class ChatFramePacingMonitor: NSObject {
    private var displayLink: CADisplayLink?
    private var timestamps: [CFTimeInterval] = []
    private var onFrame: ((CADisplayLink) -> Void)?
    private(set) var displayMaximumFPS = 60

    func start(
        in window: ChatBenchmarkWindow?,
        onFrame: @escaping (CADisplayLink) -> Void
    ) {
        cancel()
        #if os(macOS)
            displayMaximumFPS = window?.screen?.maximumFramesPerSecond ?? 60
        #else
            displayMaximumFPS =
                window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        #endif
        self.onFrame = onFrame
        timestamps.removeAll(keepingCapacity: true)
        timestamps.reserveCapacity(displayMaximumFPS * 60)

        #if os(macOS)
            guard let link = window?.screen?.displayLink(
                target: self,
                selector: #selector(tick(_:))
            ) else { return }
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
    }

    /// Stops recording and reduces the samples. Returns nil for runs too
    /// short to summarize meaningfully.
    func stop(label: String) -> ChatFramePacingReport? {
        cancel()
        defer { timestamps.removeAll(keepingCapacity: false) }
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
        // A frame is a hitch when it stayed on screen at least half a refresh
        // longer than intended; the tolerance absorbs normal timer jitter.
        let hitchThreshold = expected * 1.5
        var hitchCount = 0
        var hitchTime = 0.0
        for interval in intervals where interval > hitchThreshold {
            hitchCount += 1
            hitchTime += interval - expected
        }

        func percentile(_ q: Double) -> Double {
            let index = Int(Double(intervals.count - 1) * q)
            return intervals[index] * 1_000
        }

        return ChatFramePacingReport(
            label: label,
            displayMaximumFPS: displayMaximumFPS,
            frameCount: timestamps.count,
            durationSeconds: duration,
            averageFPS: Double(intervals.count) / duration,
            expectedFrameMilliseconds: expected * 1_000,
            p50FrameMilliseconds: percentile(0.5),
            p95FrameMilliseconds: percentile(0.95),
            p99FrameMilliseconds: percentile(0.99),
            maxFrameMilliseconds: (intervals.last ?? 0) * 1_000,
            hitchCount: hitchCount,
            hitchTimeMillisecondsPerSecond: hitchTime * 1_000 / duration
        )
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        onFrame = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        timestamps.append(link.timestamp)
        onFrame?(link)
    }
}

/// Runs frame-pacing benchmarks against the live chat surface: a constant
/// velocity scroll sweep that realizes rows exactly like a user flick, and a
/// passive monitor for streaming runs. Results are logged for headless
/// harvesting and kept for in-app display.
@Observable
final class ChatBenchmarkModel {
    private static let logger = Logger(
        subsystem: "com.aqothy.mai",
        category: "ChatBenchmark"
    )

    private(set) var isRunning = false
    private(set) var reports: [ChatFramePacingReport] = []
    var latestReport: ChatFramePacingReport?

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
        #if os(macOS)
            if let webDriver = ChatWebTranscriptBenchmarkRegistry.activeDriver {
                Self.note("benchmark start: web-\(label)")
                isRunning = true
                defer { isRunning = false }
                guard let report = await webDriver.runScrollBenchmark(
                    pointsPerSecond: pointsPerSecond,
                    maximumSweepSeconds: maximumSweepSeconds,
                    label: label,
                    displayMaximumFPS: window.screen?.maximumFramesPerSecond ?? 60
                ) else {
                    Self.note("benchmark skipped: web transcript was not ready")
                    return nil
                }
                return finish(report)
            }
        #endif
        guard let scrollView = Self.transcriptScrollView(in: window) else {
            Self.note("benchmark skipped: no transcript scroll view")
            return nil
        }
        Self.note("benchmark start: \(label)")
        isRunning = true
        Self.beginSyntheticUserScroll(on: scrollView)
        defer {
            Self.endSyntheticUserScroll(on: scrollView)
            isRunning = false
        }

        let monitor = ChatFramePacingMonitor()
        var scrollsUpward = true
        var offsetY = Self.contentOffsetY(of: scrollView)
        var lastTimestamp: CFTimeInterval?
        var phaseStartTimestamp: CFTimeInterval?
        var finished = false

        await withCheckedContinuation { continuation in
            monitor.start(in: window) { link in
                guard !finished else { return }
                let timestamp = link.timestamp
                let elapsed = timestamp - (lastTimestamp ?? timestamp)
                lastTimestamp = timestamp
                phaseStartTimestamp = phaseStartTimestamp ?? timestamp

                let (minY, maxY) = Self.scrollableRange(of: scrollView)
                offsetY += (scrollsUpward ? -1 : 1) * pointsPerSecond * elapsed
                offsetY = min(max(offsetY, minY), maxY)
                Self.setContentOffsetY(offsetY, on: scrollView)

                let phaseElapsed = timestamp - (phaseStartTimestamp ?? timestamp)
                let reachedEnd = scrollsUpward ? offsetY <= minY : offsetY >= maxY
                if reachedEnd || phaseElapsed >= maximumSweepSeconds {
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
        return finish(monitor, label: label)
    }

    /// The benchmark writes native offsets directly, so bracket the sweep in
    /// the same AppKit live-scroll lifecycle as a real trackpad gesture. This
    /// keeps production intent detection enabled without making layout-only
    /// bounds changes look like user input.
    private static func beginSyntheticUserScroll(
        on scrollView: ChatBenchmarkScrollView
    ) {
        #if os(macOS)
            NotificationCenter.default.post(
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
        #endif
    }

    private static func endSyntheticUserScroll(
        on scrollView: ChatBenchmarkScrollView
    ) {
        #if os(macOS)
            NotificationCenter.default.post(
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )
        #endif
    }

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
        Self.note("benchmark start: \(label)")
        isRunning = true
        defer { isRunning = false }

        let monitor = ChatFramePacingMonitor()
        var startTimestamp: CFTimeInterval?
        var finished = false

        await withCheckedContinuation { continuation in
            monitor.start(in: window) { link in
                guard !finished else { return }
                startTimestamp = startTimestamp ?? link.timestamp
                let elapsed = link.timestamp - (startTimestamp ?? link.timestamp)
                if isDone() || elapsed >= maximumSeconds {
                    finished = true
                    continuation.resume()
                }
            }
        }
        return finish(monitor, label: label)
    }

    private func finish(
        _ monitor: ChatFramePacingMonitor,
        label: String
    ) -> ChatFramePacingReport? {
        guard let report = monitor.stop(label: label) else { return nil }
        return finish(report)
    }

    private func finish(
        _ report: ChatFramePacingReport
    ) -> ChatFramePacingReport {
        reports.append(report)
        latestReport = report
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

    /// A headless launch may start measuring before any window becomes key.
    private static func appWindow() -> ChatBenchmarkWindow? {
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
    private static func transcriptScrollView(
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

    private static func setContentOffsetY(
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

/// Headless benchmarking: launching with `-ChatPerformanceLab
/// -ChatAutoBenchmark <scroll|stream|all>` opens the lab directly and runs
/// the selected passes, printing one `CHAT_BENCHMARK_RESULT` JSON line per
/// pass and `CHAT_BENCHMARK_COMPLETE` at the end.
nonisolated enum ChatBenchmarkAutoRun {
    static let logger = Logger(
        subsystem: "com.aqothy.mai",
        category: "ChatBenchmark"
    )

    static var plan: String? {
        guard ChatPerformanceLab.isEnabled else { return nil }
        return UserDefaults.standard.string(forKey: "ChatAutoBenchmark")
    }

    /// `-ChatBenchmarkThread <title substring>` benchmarks a real thread from
    /// the connected daemon instead of the mock lab.
    static var threadTitleQuery: String? {
        guard ChatPerformanceLab.isEnabled,
            let value = UserDefaults.standard.string(
                forKey: "ChatBenchmarkThread"
            )?.trimmingCharacters(in: .whitespaces),
            !value.isEmpty
        else { return nil }
        return value
    }

    /// Whether the lab has finished priming caches and layouts for the whole
    /// loaded transcript. The scroll benchmark waits for this so it measures
    /// the production steady state — production always prepares a page off
    /// the main actor before inserting it into the timeline.
    @MainActor static var isTranscriptWarm = false

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
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while !isTranscriptWarm, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if !isTranscriptWarm {
            trace("transcript warm timed out")
        }
    }

    /// Headless runs also append results to a file: stdout is lost under
    /// `open`, and ad-hoc launched builds may not reach the unified log.
    static func trace(_ message: String) {
        guard plan != nil else { return }
        let url = URL(fileURLWithPath: "/tmp/mai-chat-benchmark.log")
        let line = Data((message + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}
