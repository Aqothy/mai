import Foundation
import Testing
@testable import mai

struct ThreadListFilterTests {
    @Test
    func filtersByTrimmedQueryProjectAndResolvedProvider() {
        let threads = [
            ThreadFixtures.summary(
                id: "client", title: "Build the SwiftUI client", cwd: "/Users/example/App", agent: ("codex-main", "Codex")),
            ThreadFixtures.summary(
                id: "api", title: "Review the WebSocket API", cwd: "/Users/example/Server", agent: ("registry-codex", "Codex")),
            ThreadFixtures.summary(id: "none", title: "Untitled", agent: ("gone", "Gone")),
            ThreadFixtures.summary(
                id: "sub", title: "Swift subagent", cwd: "/Users/example/App", agent: ("codex-main", "Codex"),
                parent: "client"),
        ]
        // Threads carry instance IDs; the filter matches the resolved provider.
        let providerForThread: (ThreadSummary) -> String? = { thread in
            switch thread.participants.first?.instance {
            case "codex-main": "codex"
            case "registry-codex": "acp"
            default: nil
            }
        }
        // A chat an agent started shows under its parent, except in a search.
        let cases: [(query: String, project: String?, provider: String?, expected: [String])] = [
            ("   ", nil, nil, ["client", "api", "none"]),
            ("  THE SWIFT  ", nil, nil, ["client"]),
            ("swift", nil, nil, ["client", "sub"]),
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
}
