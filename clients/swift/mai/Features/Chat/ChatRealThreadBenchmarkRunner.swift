import OSLog
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Runs the frame-pacing scroll benchmark against a real thread from the
/// connected daemon instead of the mock performance lab:
///
///     -ChatPerformanceLab -ChatAutoBenchmark scroll -ChatBenchmarkThread "<title substring>"
///
/// The runner waits for the thread list, selects the first thread whose
/// title matches, waits for its history to restore and its markdown and
/// text-layout caches to be prepared, then drives the same sweep velocities
/// as the lab. Only the scroll plan is meaningful here — streaming against a
/// real agent would send a live prompt — so any other plan value still runs
/// only the sweeps.
struct ChatRealThreadBenchmarkRunner: ViewModifier {
    let store: ThreadStore
    let selectThread: (String) -> Void

    @State private var benchmark = ChatBenchmarkModel()
    @State private var didRun = false

    func body(content: Content) -> some View {
        content.task {
            guard !didRun,
                ChatBenchmarkAutoRun.plan != nil,
                let query = ChatBenchmarkAutoRun.threadTitleQuery
            else { return }
            didRun = true
            await run(query: query)
        }
    }

    private func run(query: String) async {
        let started = ContinuousClock.now
        ChatBenchmarkAutoRun.trace("real-thread benchmark start: \(query)")
        pinWindowForDeterministicRuns()

        guard let entry = await waitForThread(matching: query) else {
            finish("real-thread benchmark: no thread matching \"\(query)\"")
            return
        }
        ChatBenchmarkAutoRun.trace(
            "real-thread benchmark thread: \(entry.id) \(entry.title)"
        )
        selectThread(entry.id)

        guard await waitForSelectedThreadLoaded() else {
            finish("real-thread benchmark: thread failed to load")
            return
        }
        #if os(macOS)
            if ChatBenchmarkAutoRun.plan == "open" {
                await ChatBenchmarkAutoRun.awaitTranscriptWarm(timeoutSeconds: 180)
                let deadline = ContinuousClock.now + .seconds(30)
                while !ChatBenchmarkAutoRun.isInitialAlignmentComplete,
                    ContinuousClock.now < deadline
                {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                benchmark.reportOpenBenchmark(started: started)
                finish("CHAT_BENCHMARK_COMPLETE")
                return
            }
        #endif
        #if os(macOS) && DEBUG
            if ["sessions", "sessionsResize"].contains(ChatBenchmarkAutoRun.plan ?? "") {
                await runSessionMemoryBenchmark()
                finish("CHAT_BENCHMARK_COMPLETE")
                return
            }
        #endif
        // Let the initial mount settle at the bottom anchor, then wait for
        // the timeline's preparation task to finish priming every cache the
        // sweep will touch.
        try? await Task.sleep(for: .seconds(3))
        await ChatBenchmarkAutoRun.awaitTranscriptWarm(timeoutSeconds: 180)

        #if os(macOS) && DEBUG
            if ChatBenchmarkAutoRun.plan == "lifecycle" {
                await benchmark.runNativeLifecycleBenchmark()
                finish("CHAT_BENCHMARK_COMPLETE")
                return
            }
        #endif

        #if DEBUG
            if ChatBenchmarkAutoRun.syntheticThreadTurnCount != nil,
                let plan = ChatBenchmarkAutoRun.plan, plan == "stream" || plan == "streamScroll"
            {
                let driver = ChatSyntheticStreamingBenchmark(store: store)
                driver.prepare()
                try? await Task.sleep(for: .milliseconds(500))
                await ChatBenchmarkAutoRun.awaitTranscriptWarm(timeoutSeconds: 180)
                let stream = Task { await driver.run() }
                if plan == "streamScroll" {
                    _ = await benchmark.runScrollBenchmark(
                        pointsPerSecond: 3_000, maximumSweepSeconds: 10,
                        label: "production-stream-scroll-3000pps")
                } else {
                    _ = await benchmark.runStreamingBenchmark(
                        label: "production-stream-20000chars",
                        maximumSeconds: 60, isDone: { driver.isFinished })
                }
                await stream.value
                ChatBenchmarkAutoRun.trace(
                    "stream sourceMatches=\(driver.sourceMatches) completed=\(driver.isFinished)")
                finish("CHAT_BENCHMARK_COMPLETE")
                return
            }
        #endif

        if ChatBenchmarkAutoRun.plan == "scrub" {
            _ = await benchmark.runScrollBenchmark(
                pointsPerSecond: 3_000,
                maximumSweepSeconds: 10, label: "full-history-scrub")
            finish("CHAT_BENCHMARK_COMPLETE")
            return
        }

        _ = await benchmark.runScrollBenchmark(
            pointsPerSecond: 1_200,
            maximumSweepSeconds: 10,
            label: "real-cruise-1200pps"
        )
        try? await Task.sleep(for: .seconds(1))
        _ = await benchmark.runScrollBenchmark(
            pointsPerSecond: 3_000,
            maximumSweepSeconds: 12,
            label: "real-scroll-3000pps"
        )
        try? await Task.sleep(for: .seconds(1))
        _ = await benchmark.runScrollBenchmark(
            pointsPerSecond: 8_000,
            maximumSweepSeconds: 8,
            label: "real-fling-8000pps"
        )
        finish("CHAT_BENCHMARK_COMPLETE")
    }

    #if os(macOS) && DEBUG
        private func runSessionMemoryBenchmark() async {
            guard let turns = ChatBenchmarkAutoRun.syntheticThreadTurnCount,
                let window = ChatBenchmarkModel.appWindow()
            else { return }
            for index in 1...5 {
                let started = ContinuousClock.now
                if index > 1 {
                    let thread = ChatSyntheticBenchmarkThread.thread(
                        turnCount: turns,
                        identity: "synthetic-benchmark-\(index)")
                    store.insertSyntheticBenchmarkThread(thread)
                    ChatBenchmarkAutoRun.isTranscriptWarm = false
                    ChatBenchmarkAutoRun.isInitialAlignmentComplete = false
                    selectThread(thread.id)
                }
                await ChatBenchmarkAutoRun.awaitTranscriptWarm(timeoutSeconds: 180)
                let deadline = ContinuousClock.now + .seconds(30)
                while !ChatBenchmarkAutoRun.isInitialAlignmentComplete,
                    ContinuousClock.now < deadline
                {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                if ChatBenchmarkAutoRun.plan == "sessionsResize" {
                    for width in [1000.0, 800.0, 700.0, 1280.0] {
                        ChatBenchmarkAutoRun.isTranscriptWarm = false
                        window.setContentSize(NSSize(width: width, height: 900))
                        try? await Task.sleep(for: .milliseconds(250))
                        await ChatBenchmarkAutoRun.awaitTranscriptWarm(timeoutSeconds: 180)
                        guard window.occlusionState.contains(.visible) else {
                            ChatBenchmarkAutoRun.trace(
                                "invalid measurement: memory resize window hidden")
                            return
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
                guard window.occlusionState.contains(.visible) else {
                    ChatBenchmarkAutoRun.trace(
                        "invalid measurement: memory checkpoint window hidden")
                    return
                }
                let elapsed = started.duration(to: .now).components
                let payload: [String: Any] = [
                    "label": "sessions-\(index)", "measurementKind": "sessionMemoryCheckpoint",
                    "loadedChats": index,
                    "preparedAndSettledMilliseconds": Double(elapsed.seconds) * 1000 + Double(
                        elapsed.attoseconds) / 1e15,
                    "selectedLayoutCount": store.selectedThreadTextLayoutStore?.cachedLayoutCount
                        ?? 0,
                    "aligned": ChatBenchmarkAutoRun.isInitialAlignmentComplete,
                    "visible": window.occlusionState.contains(.visible),
                    "windowWidth": window.frame.width,
                ]
                if let data = try? JSONSerialization.data(
                    withJSONObject: payload, options: [.sortedKeys]),
                    let line = String(data: data, encoding: .utf8)
                {
                    print("CHAT_BENCHMARK_RESULT \(line)")
                    ChatBenchmarkAutoRun.trace("session checkpoint \(index)")
                }
                // Give the external runner time to sample this process after each chat.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    #endif

    private func waitForThread(
        matching query: String
    ) async -> ThreadListEntry? {
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            let threads = store.threads
            if !threads.isEmpty {
                if let match = threads.first(where: {
                    $0.title.localizedCaseInsensitiveContains(query)
                }) {
                    return match
                }
                // The list is populated and no title matches; more waiting
                // will not change that once the connection is synchronized.
                if store.connectionState == .connected {
                    return nil
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func waitForSelectedThreadLoaded() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            if store.selectedThreadLoadErrorMessage != nil
                || store.selectedThreadHistoryRestoreErrorMessage != nil
            {
                return false
            }
            if let thread = store.selectedThread,
                !thread.timeline.isEmpty,
                store.selectedThreadMarkdownSegmentCache != nil,
                !store.isSelectedThreadRestoringHistory
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func finish(_ message: String) {
        ChatBenchmarkAutoRun.logger.notice("\(message, privacy: .public)")
        ChatBenchmarkAutoRun.trace(message)
        print(message)
        if message != "CHAT_BENCHMARK_COMPLETE" {
            ChatBenchmarkAutoRun.trace("CHAT_BENCHMARK_COMPLETE")
            print("CHAT_BENCHMARK_COMPLETE")
        }
    }

    /// A deterministic window keeps runs comparable across launches.
    private func pinWindowForDeterministicRuns() {
        #if os(macOS)
            NSApplication.shared.activate()
            for window in NSApplication.shared.windows {
                window.setContentSize(NSSize(width: 1_280, height: 900))
                window.makeKeyAndOrderFront(nil)
            }
        #else
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene,
                    let restrictions = windowScene.sizeRestrictions
                else { continue }
                restrictions.minimumSize = CGSize(width: 1_280, height: 900)
                restrictions.maximumSize = CGSize(width: 1_280, height: 900)
            }
        #endif
    }
}
