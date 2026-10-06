import Foundation
import Testing

@testable import mai

struct ACPRegistryModelTests {
    @Test
    func sameNamedProvidersRemainDistinguishable() async throws {
        let rpc = ACPRegistryMockRPCClient()
        rpc.providers = [try newJSONDecoder().decode(InstanceInfo.self, from: Data("""
            {"auth":{"status":"authenticated"},"capabilities":{},"driver":"codex-app-server",
             "instanceId":"codex-app-server","name":"Codex","status":"initialized",
             "initializedAt":"2026-09-23T00:00:00Z","startedAt":"2026-09-23T00:00:00Z"}
            """.utf8))]
        _ = try await rpc.installRegistryAgent("codex-acp")
        rpc.installedAgents += [
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
        rpc.registryAgents = [
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
        ]
        rpc.installedAgents = [makeCustomAgent(id: "Local Agent", name: "Local Agent")]
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
    func addingCustomAgentUsesNameDerivedIdentityWithoutStartingAProvider() async throws {
        let rpc = ACPRegistryMockRPCClient()
        let store = ThreadStore(rpc: rpc)
        let configuration = try CustomACPAgentConfiguration(
            name: "My Agent",
            command: "/usr/local/bin/my-agent",
            argumentText: "--acp --profile work",
            environment: [("API_URL", "https://example.test")]
        )

        let installed = try await store.addCustomACPAgent(configuration)

        #expect(installed.id == "My Agent")
        #expect(installed.instanceID == "custom-My Agent")
        #expect(store.availableProviders.map(\.id) == ["custom-My Agent"])
        #expect(rpc.providers.isEmpty)
        let input = try #require(rpc.customAgentInput)
        #expect(input.name == "My Agent")
        #expect(input.command == "/usr/local/bin/my-agent")
        #expect(input.args == ["--acp", "--profile", "work"])
        #expect(input.env == ["API_URL": "https://example.test"])
    }

    @Test
    func customAgentOccupyingRegistryIDReplacesCatalogEntry() async throws {
        let rpc = ACPRegistryMockRPCClient()
        rpc.registryAgents = [
            makeRegistryAgent(
                id: "codex-acp",
                name: "Codex",
                description: "Registry description"
            )
        ]
        rpc.installedAgents = [makeCustomAgent(id: "codex-acp", name: "codex-acp")]
        let store = ThreadStore(rpc: rpc)
        await store.start()
        let model = ACPRegistryModel(store: store)
        await model.load()

        #expect(model.entries.count == 1)
        let entry = try #require(model.entries.first)
        #expect(entry.id == "codex-acp")
        #expect(entry.name == "codex-acp")
        #expect(entry.source == .custom)
        #expect(entry.isInstalled)
        #expect(!entry.hasUpdate)
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
    var registryAgents: [ACPRegistryAgent] = []
    var installedAgents: [ACPRegistryInstalledAgent] = []
    var providers: [InstanceInfo] = []
    private(set) var customAgentInput: ACPCustomAgentAddParams?

    func installRegistryAgent(_ registryID: String) async throws -> ACPRegistryInstalledAgent {
        let installed = ACPRegistryInstalledAgent(
            args: nil, description: nil, icon: nil, id: registryID, installedAt: .now,
            instanceID: "registry-\(registryID)", name: "Codex", package: "codex-acp@2.0.0",
            source: "registry", version: "2.0.0")
        installedAgents = [installed]
        return installed
    }

    func connect() {}
    func disconnect() {}

    func subscribeThreadList() async throws -> ThreadListStreamItem {
        ThreadListStreamItem(
            kind: "snapshot",
            sequence: nil,
            snapshot: ThreadListSnapshot(
                snapshotSequence: 0,
                threads: [],
                updatedAt: .now
            ),
            thread: nil
        )
    }

    func subscribeThread(_ input: SubscribeThreadInput) async throws -> ThreadStreamItem {
        throw RPCError("Thread subscriptions are unavailable")
    }

    func unsubscribeThread(_ input: SubscribeThreadInput) async throws {}
    func listProviders() async throws -> [InstanceInfo] { providers }
    func listRegistryAgents() async throws -> [ACPRegistryAgent] { registryAgents }
    func listInstalledAgents() async throws -> [ACPRegistryInstalledAgent] { installedAgents }

    func addCustomACPAgent(_ input: ACPCustomAgentAddParams) async throws -> ACPRegistryInstalledAgent {
        customAgentInput = input
        let installed = ACPRegistryInstalledAgent(
            args: input.args,
            description: nil,
            icon: nil,
            id: input.name,
            installedAt: .now,
            instanceID: "custom-\(input.name)",
            name: input.name,
            package: "",
            source: "custom",
            version: ""
        )
        installedAgents.append(installed)
        return installed
    }
}

private func makeCustomAgent(id: String, name: String) -> ACPRegistryInstalledAgent {
    ACPRegistryInstalledAgent(
        args: nil,
        description: nil,
        icon: nil,
        id: id,
        installedAt: .now,
        instanceID: "custom-\(id)",
        name: name,
        package: "",
        source: "custom",
        version: ""
    )
}

private func makeRegistryAgent(
    id: String,
    name: String,
    description: String,
    icon: String? = nil
) -> ACPRegistryAgent {
    ACPRegistryAgent(
        args: nil,
        description: description,
        icon: icon,
        id: id,
        instanceID: "registry-\(id)",
        name: name,
        package: "\(id)-acp@1.0.0",
        version: "1.0.0"
    )
}
