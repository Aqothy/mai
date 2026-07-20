#if DEBUG
import Foundation

enum PreviewData {
    static let workingTurn = Turn(
        completedAt: nil,
        error: nil,
        interruptRequested: nil,
        requestedAt: .now,
        startedAt: .now,
        state: "running",
        stopReason: nil,
        turnID: "preview-turn"
    )

    static let selectedThread = Thread(
        createdAt: .now.addingTimeInterval(-3_600),
        cwd: "/Users/example/Project",
        draft: false,
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
            draft: false,
            hasPendingApprovals: false,
            id: selectedThread.id,
            latestTurn: workingTurn,
            modelSelection: nil,
            providerInstanceID: selectedThread.providerInstanceID,
            session: nil,
            title: selectedThread.title,
            updatedAt: .now
        ),
        ThreadListEntry(
            createdAt: .now.addingTimeInterval(-86_400),
            cwd: "/Users/example/Server",
            draft: false,
            hasPendingApprovals: true,
            id: "preview-thread-2",
            latestTurn: nil,
            modelSelection: nil,
            providerInstanceID: "codex",
            session: nil,
            title: "Review the WebSocket API",
            updatedAt: .now.addingTimeInterval(-1_800)
        ),
        ThreadListEntry(
            createdAt: .now.addingTimeInterval(-172_800),
            cwd: nil,
            draft: false,
            hasPendingApprovals: false,
            id: "preview-thread-3",
            latestTurn: nil,
            modelSelection: nil,
            providerInstanceID: "gemini",
            session: nil,
            title: "Improve thread navigation",
            updatedAt: .now.addingTimeInterval(-86_400)
        )
    ]
}
#endif
