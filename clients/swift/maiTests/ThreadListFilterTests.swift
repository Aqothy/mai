import Foundation
import Testing
@testable import mai

struct ThreadListFilterTests {
    @Test
    func emptyQueryMatchesEverything() {
        var filter = ThreadListFilter()
        filter.query = "   "
        let threads = [
            makeEntry(id: "a", title: "Build the SwiftUI client"),
            makeEntry(id: "b", title: "Review the WebSocket API")
        ]
        let result = filter.apply(to: threads, isUnread: { _ in false }, driver: { _ in nil })
        #expect(result.count == 2)
    }

    @Test
    func queryMatchesTitleSubstringCaseInsensitively() {
        var filter = ThreadListFilter()
        filter.query = "  THE SWIFT  "
        let threads = [
            makeEntry(id: "match", title: "Build the SwiftUI client"),
            makeEntry(id: "other", title: "Review the WebSocket API")
        ]
        let result = filter.apply(to: threads, isUnread: { _ in false }, driver: { _ in nil })
        #expect(result.map(\.id) == ["match"])
    }

    @Test
    func projectFilterMatchesExactWorkingDirectory() {
        let threads = [
            makeEntry(id: "app", title: "App", cwd: "/Users/example/App"),
            makeEntry(id: "server", title: "Server", cwd: "/Users/example/Server"),
            makeEntry(id: "none", title: "None", cwd: nil)
        ]

        var filter = ThreadListFilter()
        filter.projectCwd = "/Users/example/App"
        let result = filter.apply(to: threads, isUnread: { _ in false }, driver: { _ in nil })
        #expect(result.map(\.id) == ["app"])
    }

    @Test
    func driverFilterMatchesNativeDriverOrACP() {
        let threads = [
            makeEntry(id: "claude", title: "Claude", providerInstanceID: "claude-main"),
            makeEntry(id: "codex", title: "Codex", providerInstanceID: "codex-main"),
            makeEntry(id: "acp", title: "ACP", providerInstanceID: "registry-codex"),
            makeEntry(id: "none", title: "None", providerInstanceID: nil)
        ]
        let driverForThread: (ThreadListEntry) -> String? = { thread in
            switch thread.providerInstanceID {
            case "claude-main": "claude"
            case "codex-main": "codex"
            case "registry-codex": "acp"
            default: nil
            }
        }

        var filter = ThreadListFilter()
        filter.driver = "codex"
        let native = filter.apply(to: threads, isUnread: { _ in false }, driver: driverForThread)
        #expect(native.map(\.id) == ["codex"])

        filter.driver = "acp"
        let acp = filter.apply(to: threads, isUnread: { _ in false }, driver: driverForThread)
        #expect(acp.map(\.id) == ["acp"])
    }

    @Test
    func activityFilterMatchesThreadState() {
        let threads = [
            makeEntry(id: "idle", title: "Idle"),
            makeEntry(id: "working", title: "Working", turnState: .running),
            makeEntry(id: "approval", title: "Approval", hasPendingApprovals: true)
        ]

        var filter = ThreadListFilter()
        filter.activityFilter = .working
        let working = filter.apply(to: threads, isUnread: { _ in false }, driver: { _ in nil })
        #expect(working.map(\.id) == ["working"])

        filter.activityFilter = .needsApproval
        let approvals = filter.apply(to: threads, isUnread: { _ in false }, driver: { _ in nil })
        #expect(approvals.map(\.id) == ["approval"])

        filter.activityFilter = .unread
        let unread = filter.apply(to: threads, isUnread: { $0 == "idle" }, driver: { _ in nil })
        #expect(unread.map(\.id) == ["idle"])
    }

    @Test
    func isActiveReflectsQueryAndPresets() {
        var filter = ThreadListFilter()
        #expect(!filter.isActive)

        filter.query = "   "
        #expect(!filter.isActive)

        filter.query = "swift"
        #expect(filter.isActive)
        #expect(!filter.hasActivePresets)

        filter.query = ""
        filter.projectCwd = "/Users/example/App"
        filter.driver = "codex"
        filter.activityFilter = .unread
        #expect(filter.isActive)
        #expect(filter.hasActivePresets)

        filter.resetPresets()
        #expect(!filter.isActive)
    }

    private func makeEntry(
        id: String,
        title: String,
        cwd: String? = nil,
        providerInstanceID: String? = nil,
        hasPendingApprovals: Bool = false,
        turnState: MaidTurnState? = nil
    ) -> ThreadListEntry {
        ThreadListEntry(
            createdAt: .now,
            cwd: cwd,
            hasPendingApprovals: hasPendingApprovals,
            id: id,
            latestTurn: turnState.map {
                Turn(
                    completedAt: nil,
                    error: nil,
                    interruptRequested: nil,
                    requestedAt: .now,
                    startedAt: nil,
                    state: $0.rawValue,
                    stopReason: nil,
                    turnID: "turn-\(id)"
                )
            },
            modelSelection: nil,
            providerInstanceID: providerInstanceID,
            session: nil,
            title: title,
            updatedAt: .now
        )
    }
}
