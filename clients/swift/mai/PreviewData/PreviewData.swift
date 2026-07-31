#if DEBUG
import Foundation

enum PreviewData {
    static let workingTurn = Turn(
        completedAt: nil,
        error: nil,
        interruptRequested: nil,
        requestedAt: .now,
        startedAt: .now,
        state: MaidTurnState.running.rawValue,
        stopReason: nil,
        turnID: "preview-turn"
    )

    static let selectedThread = Thread(
        createdAt: .now.addingTimeInterval(-3_600),
        cwd: "/Users/example/Project",
        id: "preview-thread-1",
        latestTurn: workingTurn,
        modelSelection: nil,
        plan: nil,
        providerInstanceID: "claude-code",
        session: nil,
        timeline: [],
        title: "Build the SwiftUI client",
        updatedAt: .now
    )

    static let threads = [
        ThreadListEntry(
            createdAt: selectedThread.createdAt,
            cwd: selectedThread.cwd,
            hasPendingApprovals: false,
            id: selectedThread.id,
            latestTurn: workingTurn,
            modelSelection: nil,
            providerInstanceID: selectedThread.providerInstanceID,
            session: sessionBinding(
                threadID: selectedThread.id,
                providerInstanceID: "claude-code",
                driver: "claude",
                providerName: "Claude"
            ),
            title: selectedThread.title,
            updatedAt: .now
        ),
        ThreadListEntry(
            createdAt: .now.addingTimeInterval(-86_400),
            cwd: "/Users/example/Server",
            hasPendingApprovals: true,
            id: "preview-thread-2",
            latestTurn: nil,
            modelSelection: nil,
            providerInstanceID: "codex",
            session: sessionBinding(
                threadID: "preview-thread-2",
                providerInstanceID: "codex",
                driver: "codex",
                providerName: "Codex"
            ),
            title: "Review the WebSocket API",
            updatedAt: .now.addingTimeInterval(-1_800)
        ),
        ThreadListEntry(
            createdAt: .now.addingTimeInterval(-172_800),
            cwd: nil,
            hasPendingApprovals: false,
            id: "preview-thread-3",
            latestTurn: nil,
            modelSelection: nil,
            providerInstanceID: "registry-gemini",
            session: sessionBinding(
                threadID: "preview-thread-3",
                providerInstanceID: "registry-gemini",
                driver: "acp",
                providerName: "Gemini CLI"
            ),
            title: "Improve thread navigation",
            updatedAt: .now.addingTimeInterval(-86_400)
        )
    ]

    private static func sessionBinding(
        threadID: String,
        providerInstanceID: String,
        driver: String,
        providerName: String
    ) -> SessionBinding {
        SessionBinding(
            activeTurnID: nil,
            configOptions: nil,
            cwd: nil,
            driver: driver,
            lastError: nil,
            providerInstanceID: providerInstanceID,
            providerName: providerName,
            slashCommands: nil,
            status: MaidSessionStatus.ready.rawValue,
            stopRequested: nil,
            threadID: threadID,
            tokenUsage: nil,
            updatedAt: .now
        )
    }

    static func threadStore() -> ThreadStore {
        ThreadStore(
            previewThreads: threads,
            selectedThread: selectedThread
        )
    }
}
#endif
