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
        // Let the initial mount settle at the bottom anchor, then wait for
        // the timeline's preparation task to finish priming every cache the
        // sweep will touch.
        try? await Task.sleep(for: .seconds(3))
        await ChatBenchmarkAutoRun.awaitTranscriptWarm(timeoutSeconds: 180)

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
