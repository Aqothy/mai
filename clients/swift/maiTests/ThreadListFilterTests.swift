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
        let result = filter.apply(to: threads, providerID: { _ in nil })
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
        let result = filter.apply(to: threads, providerID: { _ in nil })
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
        let result = filter.apply(to: threads, providerID: { _ in nil })
        #expect(result.map(\.id) == ["app"])
    }

    @Test
    func providerFilterMatchesExactProviderInstance() {
        let threads = [
            makeEntry(id: "claude", title: "Claude", providerInstanceID: "claude-main"),
            makeEntry(id: "codex", title: "Codex", providerInstanceID: "codex-main"),
            makeEntry(id: "acp", title: "ACP", providerInstanceID: "registry-codex"),
            makeEntry(id: "none", title: "None", providerInstanceID: nil)
        ]
        let providerIDForThread: (ThreadListEntry) -> String? = { $0.providerInstanceID }

        var filter = ThreadListFilter()
        filter.providerID = "codex-main"
        let native = filter.apply(
            to: threads,
            providerID: providerIDForThread
        )
        #expect(native.map(\.id) == ["codex"])

        filter.providerID = "registry-codex"
        let acp = filter.apply(
            to: threads,
            providerID: providerIDForThread
        )
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
        filter.providerID = "codex"
        #expect(filter.isActive)
        #expect(filter.hasActivePresets)

        filter.resetPresets()
        #expect(!filter.isActive)
    }

    @Test
    func providerCatalogIsFlatAndExcludesUninstalledACPProviders() {
        let installedACP = makeInstalledAgent(
            id: "claude-code",
            instanceID: "registry-claude-code",
            name: "Claude Code"
        )
        let store = ThreadStore(
            previewThreads: [],
            providers: [
                makeProvider(
                    instanceID: "native-codex",
                    name: "Codex",
                    driver: "codex"
                ),
                makeProvider(
                    instanceID: installedACP.instanceID,
                    name: installedACP.name,
                    driver: "acp"
                ),
                makeProvider(
                    instanceID: "uninstalled-acp",
                    name: "Uninstalled",
                    driver: "acp"
                ),
            ],
            installedAgents: [installedACP]
        )

        #expect(store.availableProviders.map(\.id) == ["registry-claude-code", "native-codex"])
        #expect(store.availableProviders.map(\.name) == ["Claude Code", "Codex"])
    }

    @Test
    func threadRowsUseProviderNamesInsteadOfDriverNames() {
        let provider = makeProvider(
            instanceID: "native-codex",
            name: "Codex",
            driver: "codex-native-driver"
        )
        let store = ThreadStore(
            previewThreads: [],
            providers: [provider]
        )
        let thread = makeEntry(
            id: "thread",
            title: "Thread",
            providerInstanceID: provider.instanceID
        )

        #expect(store.providerDisplayName(for: thread) == "Codex")
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

    private func makeProvider(instanceID: String, name: String, driver: String) -> InstanceInfo {
        InstanceInfo(
            auth: Auth(methods: nil, status: "unknown"),
            capabilities: Capabilities(
                auth: nil,
                configOptions: nil,
                loadReplay: nil,
                logout: nil,
                mcp: nil,
                modelSwitch: nil,
                promptContent: nil,
                resume: nil,
                sessionList: nil
            ),
            driver: driver,
            initializedAt: .now,
            instanceID: instanceID,
            name: name,
            pid: nil,
            startedAt: .now,
            status: "configured"
        )
    }

    private func makeInstalledAgent(
        id: String,
        instanceID: String,
        name: String
    ) -> ACPRegistryInstalledAgent {
        ACPRegistryInstalledAgent(
            args: nil,
            description: nil,
            icon: nil,
            id: id,
            installedAt: .now,
            instanceID: instanceID,
            name: name,
            package: "\(id)@1.0.0",
            source: "registry",
            version: "1.0.0"
        )
    }
}
