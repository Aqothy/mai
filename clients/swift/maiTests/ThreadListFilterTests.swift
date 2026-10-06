import Foundation
import Testing
@testable import mai

struct ThreadListFilterTests {
    @Test
    func filtersByTrimmedQueryProjectAndResolvedProvider() {
        let threads = [
            makeEntry(id: "client", title: "Build the SwiftUI client", cwd: "/Users/example/App", providerInstanceID: "codex-main"),
            makeEntry(id: "api", title: "Review the WebSocket API", cwd: "/Users/example/Server", providerInstanceID: "registry-codex"),
            makeEntry(id: "none", title: "Untitled", cwd: nil, providerInstanceID: nil),
        ]
        // Thread entries carry instance IDs; the filter matches the resolved provider.
        let providerForThread: (ThreadListEntry) -> String? = { thread in
            switch thread.providerInstanceID {
            case "codex-main": "codex"
            case "registry-codex": "acp"
            default: nil
            }
        }
        let cases: [(query: String, project: String?, provider: String?, expected: [String])] = [
            ("   ", nil, nil, ["client", "api", "none"]),
            ("  THE SWIFT  ", nil, nil, ["client"]),
            ("", "/Users/example/App", nil, ["client"]),
            ("", nil, "acp", ["api"]),
            ("the", "/Users/example/Server", "codex", []),
        ]
        for testCase in cases {
            var filter = ThreadListFilter()
            filter.query = testCase.query
            filter.projectCwd = testCase.project
            filter.providerID = testCase.provider
            let result = filter.apply(to: threads, providerID: providerForThread)
            #expect(result.map(\.id) == testCase.expected, "\(testCase)")
        }
    }

    private func makeEntry(
        id: String,
        title: String,
        cwd: String?,
        providerInstanceID: String?
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
