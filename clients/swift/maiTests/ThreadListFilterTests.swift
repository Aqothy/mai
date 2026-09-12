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
        let result = filter.apply(to: threads, providerID: { $0.providerInstanceID })
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
        let result = filter.apply(to: threads, providerID: { $0.providerInstanceID })
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
        let result = filter.apply(to: threads, providerID: { $0.providerInstanceID })
        #expect(result.map(\.id) == ["app"])
    }

    @Test
    func providerFilterMatchesExactInstance() {
        let threads = [
            makeEntry(id: "claude", title: "Claude", providerInstanceID: "claude-main"),
            makeEntry(id: "codex", title: "Codex", providerInstanceID: "codex-main"),
            makeEntry(id: "acp", title: "ACP", providerInstanceID: "registry-codex"),
            makeEntry(id: "none", title: "None", providerInstanceID: nil)
        ]
        var filter = ThreadListFilter()
        filter.providerID = "codex-main"
        let native = filter.apply(to: threads, providerID: { $0.providerInstanceID })
        #expect(native.map(\.id) == ["codex"])

        filter.providerID = "registry-codex"
        let acp = filter.apply(to: threads, providerID: { $0.providerInstanceID })
        #expect(acp.map(\.id) == ["acp"])
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
        filter.providerID = "codex-main"
        #expect(filter.isActive)
        #expect(filter.hasActivePresets)

        filter.resetPresets()
        #expect(!filter.isActive)
    }

    private func makeEntry(
        id: String,
        title: String,
        cwd: String? = nil,
        providerInstanceID: String? = nil
    ) -> ThreadListEntry {
        ThreadListEntry(
            createdAt: .now,
            cwd: cwd,
            hasPendingApprovals: false,
            id: id,
            latestTurn: nil,
            modelSelection: nil,
            providerInstanceID: providerInstanceID,
            session: nil,
            title: title,
            updatedAt: .now
        )
    }
}
