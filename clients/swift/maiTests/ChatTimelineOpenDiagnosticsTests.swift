import XCTest

@testable import mai

#if os(iOS)
    import SwiftUI
    import UIKit

    /// Times opening ChatView against synthetic cached threads of increasing
    /// length to attribute where time-to-content goes when a big thread is
    /// selected. Prints one line per run; read them from the test console log.
    nonisolated final class ChatTimelineOpenDiagnosticsTests: XCTestCase {
        @MainActor
        func testOpenTimeAcrossTimelineLengths() {
            let clock = ContinuousClock()

            let configurations: [(entryCount: Int, sections: Int)] = [
                (40, 4), (600, 4), (40, 16), (600, 16), (40, 48), (600, 48),
            ]
            for (entryCount, sections) in configurations {
                let thread = Self.makeThread(
                    entryCount: entryCount,
                    sections: sections
                )

                let chunkStart = clock.now
                var chunkTotal = 0
                for entry in thread.timeline {
                    guard let message = entry.message,
                        ChatMarkdownChunker.isOversized(message.text)
                    else { continue }
                    chunkTotal += ChatMarkdownChunkCache.shared.chunks(
                        messageID: message.id,
                        source: message.text
                    ).count
                }
                let chunkElapsed = clock.now - chunkStart
                let messageBytes = thread.timeline
                    .compactMap { $0.message?.text.utf8.count }
                    .reduce(0, +)
                print(
                    "DIAG entries=\(entryCount) sections=\(sections) totalKB=\(messageBytes / 1024) chunkColdTotal=\(chunkElapsed) chunkRows=\(chunkTotal)"
                )

                for run in 0..<3 {
                    let store = ThreadStore(
                        previewThreads: [],
                        selectedThread: thread
                    )
                    let window = UIWindow(
                        frame: CGRect(x: 0, y: 0, width: 390, height: 844)
                    )

                    let start = clock.now
                    let hostingController = UIHostingController(
                        rootView: ChatView(
                            store: store,
                            draftStore: ThreadDraftStore()
                        )
                    )
                    window.rootViewController = hostingController
                    window.isHidden = false
                    hostingController.view.layoutIfNeeded()
                    let firstLayout = clock.now - start

                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                    hostingController.view.layoutIfNeeded()
                    let settled = clock.now - start
                    print(
                        "DIAG entries=\(entryCount) sections=\(sections) run=\(run) firstLayout=\(firstLayout) settled=\(settled)"
                    )

                    XCTAssertGreaterThan(
                        hostingController.view.bounds.height,
                        0
                    )
                    window.isHidden = true
                    window.rootViewController = nil
                }
            }
        }

        @MainActor
        private static func makeThread(
            entryCount: Int,
            sections: Int
        ) -> mai.Thread {
            let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
            var entries: [TimelineEntry] = []
            entries.reserveCapacity(entryCount)

            for index in 0..<entryCount {
                let isUser = index.isMultiple(of: 2)
                let message = Message(
                    attachments: nil,
                    createdAt: baseDate.addingTimeInterval(Double(index)),
                    id: "diag-\(entryCount)-\(sections)-\(index)",
                    role: isUser
                        ? MaidMessageRole.user.rawValue
                        : MaidMessageRole.assistant.rawValue,
                    text: isUser
                        ? "Please explain step \(index) of the migration in detail."
                        : Self.assistantMarkdown(index: index, sections: sections),
                    turnID: "turn-\(index / 2)",
                    updatedAt: baseDate.addingTimeInterval(Double(index))
                )
                entries.append(
                    TimelineEntry(
                        approval: nil,
                        item: nil,
                        kind: MaidTimelineEntryKind.message.rawValue,
                        message: message
                    )
                )
            }

            return mai.Thread(
                createdAt: baseDate,
                cwd: nil,
                id: "diagnostics-thread-\(entryCount)-\(sections)",
                latestTurn: nil,
                modelSelection: nil,
                plan: nil,
                providerInstanceID: nil,
                session: nil,
                timeline: entries,
                title: "Diagnostics \(entryCount)",
                updatedAt: baseDate
            )
        }

        /// ~0.8KB of mixed markdown per section; 16 sections crosses the
        /// chunking threshold, matching a long real reply.
        private static func assistantMarkdown(index: Int, sections sectionCount: Int) -> String {
            var sections: [String] = []
            for section in 0..<sectionCount {
                sections.append(
                    """
                    ## Step \(index).\(section)

                    This paragraph describes part \(section) of response \(index)
                    with enough prose to wrap several lines at chat width and
                    remain representative of a long assistant reply in a real
                    conversation about a substantial refactor.

                    - Keep the public API stable while migrating call sites.
                    - Move shared logic into the new module before deleting.
                    - Verify each target still builds after every move.

                    ```swift
                    struct Migration\(index)Step\(section) {
                        let ordinal = \(section)
                        func apply(to target: inout [String]) {
                            target.append("step-\(section)")
                        }
                    }
                    ```
                    """
                )
            }
            return sections.joined(separator: "\n\n")
        }
    }
#endif
