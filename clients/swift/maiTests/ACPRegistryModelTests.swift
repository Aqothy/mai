import Foundation
import Testing

@testable import mai

struct ACPRegistryModelTests {
    @Test
    func sameNamedProvidersRemainDistinguishable() async throws {
        let rpc = ACPRegistryMockRPCClient()
        rpc.providers = [try newJSONDecoder().decode(InstanceInfo.self, from: Data("""
            {"auth":{"status":"authenticated"},"capabilities":{"history":"exact","historyVersion":1},"driver":"codex-app-server",
             "instanceId":"codex-app-server","name":"Codex","status":"initialized",
             "initializedAt":"2026-09-23T00:00:00Z","startedAt":"2026-09-23T00:00:00Z"}
            """.utf8))]
        rpc.agents = [
            makeInstalledAgent(id: "codex-acp", name: "Codex"),
            makeCustomAgent(id: "Codex", name: "Codex"),
            makeCustomAgent(id: "Gemini", name: "Gemini"),
        ]
        let store = ThreadStore(rpc: rpc)
        await store.start()

        let choices = store.availableProviders
        #expect(choices.map(\.id) == ["codex-app-server", "custom-Codex", "registry-codex-acp", "custom-Gemini"])
        #expect(choices.map(\.kind) == ["Built-in", "Custom ACP", "ACP Registry", "Custom ACP"])
        #expect(choices.map(\.title) == [
            "Codex (Built-in)", "Codex (Custom ACP)", "Codex (ACP Registry)", "Gemini",
        ])

        let suite = "SameNamedProviders-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let draft = DraftPromptModel(store: store, draftStore: ThreadDraftStore(defaults: defaults))
        draft.selectProvider(id: "registry-codex-acp")
        #expect(draft.selectedProviderID == "registry-codex-acp")
        #expect(draft.providerLabel == "Codex (ACP Registry)")
    }

    @Test
    func searchMatchesNamesDescriptionsIDsAndCustomAgents() async throws {
        let rpc = ACPRegistryMockRPCClient()
        rpc.agents = [
            makeRegistryAgent(
                id: "codex",
                name: "Codex",
                description: "OpenAI coding agent",
                icon: "https://cdn.example.test/codex.svg"
            ),
            makeRegistryAgent(
                id: "claude-code",
                name: "Claude Code",
                description: "Anthropic coding agent"
            ),
            makeCustomAgent(id: "Local Agent", name: "Local Agent"),
        ]
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let model = ACPRegistryModel(store: store)
        await model.load()

        #expect(model.entries.map(\.name) == ["Claude Code", "Codex", "Local Agent"])
        #expect(
            model.entries.first(where: { $0.id == "codex" })?.iconURL
                == URL(string: "https://cdn.example.test/codex.svg")
        )

        model.searchText = "openai"
        #expect(model.entries.map(\.id) == ["codex"])

        model.searchText = "LOCAL AGENT"
        #expect(model.entries.map(\.id) == ["Local Agent"])

        model.searchText = ""
        model.filter = .installed
        #expect(model.entries.map(\.id) == ["Local Agent"])

        model.filter = .notInstalled
        #expect(model.entries.map(\.id) == ["claude-code", "codex"])
    }

    @Test
    func removingAnAgentDropsItEverywhereAndARefusalKeepsIt() async throws {
        let rpc = ACPRegistryMockRPCClient()
        rpc.agents = [makeCustomAgent(id: "gemini-id", name: "Gemini")]
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let model = ACPRegistryModel(store: store)
        await model.load()
        let entry = try #require(model.entries.first)

        rpc.removalRefusal = RPCError("Gemini is working on a turn. Stop it before removing the agent.")
        await model.remove(entry)
        #expect(model.errorMessage == "Gemini is working on a turn. Stop it before removing the agent.")
        #expect(model.entries.map(\.id) == ["gemini-id"])
        #expect(store.availableProviders.map(\.id) == ["custom-gemini-id"])
        #expect(model.busyIDs.isEmpty)

        rpc.removalRefusal = nil
        await model.remove(entry)
        #expect(rpc.removedIDs == ["gemini-id", "gemini-id"])
        #expect(model.entries.isEmpty)
        #expect(store.availableProviders.isEmpty)
    }

    /// What the daemon says happens to a row, on any device: the row follows,
    /// and only an installed agent reaches the provider picker.
    @Test
    func rowsFollowTheDaemonsList() async throws {
        let rpc = ACPRegistryMockRPCClient()
        rpc.agents = [makeRegistryAgent(id: "goose", name: "Goose", description: "An agent")]
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let model = ACPRegistryModel(store: store)
        await model.load()
        #expect(model.entries.first?.isInstalled == false)

        await rpc.send(.preview(id: "goose", name: "Goose", state: .installing, availableVersion: "1.0.0"))
        model.rebuildEntries()
        #expect(model.entries.first?.isWorking == true)
        #expect(store.availableProviders.isEmpty)

        await rpc.send(.preview(id: "goose", name: "Goose", state: .failed, availableVersion: "1.0.0", error: "npm failed"))
        model.rebuildEntries()
        #expect(model.entries.first?.errorMessage == "npm failed")
        #expect(model.entries.first?.isInstalled == false)

        let released = Date(timeIntervalSince1970: 1_800_000_000)
        await rpc.send(.preview(
            id: "goose", name: "Goose", installedVersion: "1.0.0", availableVersion: "2.0.0", availableReleasedAt: released
        ))
        model.rebuildEntries()
        let updatable = try #require(model.entries.first)
        #expect(updatable.hasUpdate)
        #expect(updatable.versionLabel.hasPrefix("1.0.0 · 2.0.0 available, released"))
        #expect(store.availableProviders.map(\.id) == ["registry-goose"])
    }

    @Test
    func linksFromTheIndexAreWebOnly() throws {
        var agent = ACPRegistryAgent.preview(id: "a", name: "A")
        agent.repository = "javascript:alert(1)"
        agent.website = "file:///etc/passwd"
        agent.licenseURL = "https://example.test/license"
        let entry = ACPRegistryEntry(agent)
        #expect(entry.repositoryURL == nil)
        #expect(entry.websiteURL == nil)
        #expect(entry.licenseURL == URL(string: "https://example.test/license"))
    }

    @Test
    func customConfigurationNormalizesUserFacingFieldsAndValidatesEnvironment() throws {
        let configuration = try CustomACPAgentConfiguration(
            name: "  Démo Agent  ",
            command: "  node  ",
            argumentText: "index.js --acp",
            environment: [(" MODE ", "test"), ("", "ignored")]
        )

        #expect(configuration.name == "Démo Agent")
        #expect(configuration.command == "node")
        #expect(configuration.arguments == ["index.js", "--acp"])
        #expect(configuration.environment == ["MODE": "test"])

        #expect(throws: CustomACPAgentValidationError.duplicateEnvironmentVariable("MODE")) {
            try CustomACPAgentConfiguration(
                name: "Agent",
                command: "agent",
                argumentText: "",
                environment: [("MODE", "one"), (" MODE ", "two")]
            )
        }
    }
}

private final class ACPRegistryMockRPCClient: ThreadRPCClient {
    var onNotification: ((String, Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var agents: [ACPRegistryAgent] = []
    var providers: [InstanceInfo] = []
    var removedIDs: [String] = []
    var removalRefusal: RPCError?

    /// Sends the row the way the daemon does: as the whole list, notified.
    func send(_ agent: ACPRegistryAgent) async {
        agents = [agent]
        notifyList()
    }

    private func notifyList() {
        let params = ACPRegistryList(agents: agents)
        struct Frame: Encodable { let params: ACPRegistryList }
        let encoder = newJSONEncoder()
        guard let data = try? encoder.encode(Frame(params: params)) else { return }
        onNotification?(MaidRPCMethod.acpRegistryList, data)
    }

    func removeInstalledAgent(_ registryID: String) async throws {
        removedIDs.append(registryID)
        if let removalRefusal { throw removalRefusal }
        agents.removeAll { $0.id == registryID }
        notifyList()
    }

    func connect() {}
    func disconnect() {}
    func checkConnection() {}

    func subscribeThreadList() async throws -> ThreadListItem {
        ThreadListItem(kind: MaidThreadListKind.snapshot.rawValue, removed: nil, seq: 0, thread: nil, threads: [])
    }

    func subscribeThread(_ threadID: String) async throws -> ThreadSnapshot {
        throw RPCError("Thread subscriptions are unavailable")
    }

    func listProviders() async throws -> [InstanceInfo] { providers }
    func subscribeRegistryList() async throws -> ACPRegistryList { ACPRegistryList(agents: agents) }
    func refreshRegistry() async throws -> ACPRegistryList { ACPRegistryList(agents: agents) }
}

private func makeCustomAgent(id: String, name: String) -> ACPRegistryAgent {
    .preview(id: id, name: name, source: .custom)
}

private func makeInstalledAgent(id: String, name: String) -> ACPRegistryAgent {
    .preview(id: id, name: name, installedVersion: "2.0.0")
}

private func makeRegistryAgent(
    id: String,
    name: String,
    description: String,
    icon: String? = nil
) -> ACPRegistryAgent {
    .preview(
        id: id, name: name, state: .notInstalled, description: description, icon: icon, availableVersion: "1.0.0"
    )
}
