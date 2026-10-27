#if DEBUG
import Foundation

enum PreviewData {
    static let threads = [
        ThreadFixtures.summary(
            id: "preview-thread-1",
            title: "Build the SwiftUI client",
            cwd: "/Users/example/Project",
            status: .running,
            children: 2,
            createdAt: .now.addingTimeInterval(-3_600)
        ),
        ThreadFixtures.summary(
            id: "preview-thread-2",
            title: "Review the WebSocket API",
            cwd: "/Users/example/Server",
            agent: ("codex", "Codex"),
            needsInput: true,
            createdAt: .now.addingTimeInterval(-86_400),
            updatedAt: .now.addingTimeInterval(-1_800)
        ),
        ThreadFixtures.summary(
            id: "preview-thread-3",
            title: "Improve thread navigation",
            agent: ("registry-gemini", "Gemini CLI"),
            createdAt: .now.addingTimeInterval(-172_800),
            updatedAt: .now.addingTimeInterval(-86_400)
        ),
    ]

    static let selectedThread = ThreadFixtures.detail(
        summary: threads[0],
        turns: [
            ThreadFixtures.turn(
                id: "preview-turn",
                participant: threads[0].participants[0].id,
                state: .running,
                entries: [
                    ThreadFixtures.entry(ref: "preview-prompt", kind: .userMessage, text: "Build the SwiftUI client")
                ]
            )
        ]
    )

    static func threadStore() -> ThreadStore {
        ThreadStore(
            previewThreads: threads,
            selectedThread: selectedThread
        )
    }
}
#endif
