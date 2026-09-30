// Run via Xcode MCP on My Mac in ComposerAttachments.swift.
// Replace QA_OUTPUT and RENDERER; run capture-window.py alongside it.
do {
try await Task { @MainActor in
    let output = URL(fileURLWithPath: "QA_OUTPUT")
    let renderer = "RENDERER"
    print("SWITCH_QA_RUNTIME \(ProcessInfo.processInfo.operatingSystemVersionString) pid=\(ProcessInfo.processInfo.processIdentifier)")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "SwitchResizeQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    func save(_ name: String, _ value: Any) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appending(path: name + ".json"), options: .atomic)
    }
    @MainActor final class FixtureRPC: ThreadRPCClient {
        nonisolated deinit {}
        var onNotification: ((String, Data) -> Void)?
        var onDisconnect: (((any Error)?) -> Void)?
        let threads: [Thread]
        init(_ threads: [Thread]) { self.threads = threads }
        func connect() {}
        func disconnect() {}
        func subscribeThreadList() async throws -> ThreadListStreamItem {
            .init(kind: "snapshot", sequence: nil,
                  snapshot: .init(snapshotSequence: 0, threads: threads.map(ChatSyntheticBenchmarkThread.listEntry), updatedAt: .now), thread: nil)
        }
        func subscribeThread(_ input: SubscribeThreadInput) async throws -> ThreadStreamItem {
            guard let thread = threads.first(where: { $0.id == input.threadID }) else { throw URLError(.badURL) }
            return .init(event: nil, kind: "snapshot", snapshot: .init(historyRestorePending: false, snapshotSequence: 1, thread: thread))
        }
        func unsubscribeThread(_ input: SubscribeThreadInput) async throws {}
        func send(_ event: Event) throws {
            struct Notification: Encodable { let params: ThreadStreamItem }
            let item = ThreadStreamItem(event: event, kind: "event", snapshot: nil)
            onNotification?(MaidRPCMethod.orchestrationSubscribeThread, try newJSONEncoder().encode(Notification(params: item)))
        }
    }
    let oldArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    var arguments = oldArguments
    arguments["ChatBenchmarkUseList"] = renderer == "list"
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    defer { UserDefaults.standard.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain) }
    let suite = "mai-switch-qa-" + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: suite) else { throw URLError(.unknown) }
    defer { defaults.removePersistentDomain(forName: suite) }
    let a = ChatSyntheticBenchmarkThread.thread(turnCount: 6, identity: "qa-chat-a").with(title: "STREAM CHAT A")
    var b = a.with(id: "qa-chat-b", title: "STATIC CHAT B")
    b.session?.threadID = b.id
    b.timeline[b.timeline.count - 1].message?.id = "qa-stream-reply"
    b.timeline[b.timeline.count - 1].message?.text = "STATIC B — café 👩🏽‍💻 保持. This chat must never show the live reply from chat A."
    let comparisonEncoder = newJSONEncoder()
    comparisonEncoder.outputFormatting = .sortedKeys
    let originalB = try comparisonEncoder.encode(b)
    let originalAIDs = a.timeline.map { $0.message?.id ?? $0.item?.id ?? "missing" }
    let rpc = FixtureRPC([a, b])
    let store = ThreadStore(rpc: rpc)
    await store.start()
    store.selectThread(a.id)
    let host = NSHostingView(rootView: ChatView(store: store, draftStore: ThreadDraftStore(defaults: defaults), openThread: nil))
    host.sizingOptions = []
    let policy = NSApplication.shared.activationPolicy()
    NSApplication.shared.setActivationPolicy(.regular)
    defer { NSApplication.shared.setActivationPolicy(policy) }
    let window = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 1100, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "mai switch/resize QA " + renderer
    window.contentView = host
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    NSApplication.shared.unhide(nil)
    NSApplication.shared.activate()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.close() }
    var sequence = 1000
    @MainActor func send(_ type: MaidEventType, messageID: String? = nil, text: String? = nil, session: SessionBinding? = nil) throws {
        sequence += 1
        let payload = EventPayload(approval: nil, attachments: nil, configOptions: nil, createdAt: nil, cwd: nil, decision: nil,
            item: nil, messageID: messageID, modelSelection: nil, optionID: nil, plan: nil, providerInstanceID: nil,
            requestID: nil, role: messageID == nil ? nil : "assistant", session: session, sessionCleared: nil,
            slashCommands: nil, stopReason: nil, text: text, threadID: a.id, title: nil, tokenUsage: nil,
            turnID: "qa-stream-turn", updatedAt: nil, value: nil)
        try rpc.send(Event(actor: nil, commandID: nil, eventID: "qa-event-\(sequence)", metadata: nil, occurredAt: .now,
                           payload: payload, sequence: sequence, type: type.rawValue))
    }
    @MainActor func select(_ id: String) async throws {
        store.selectThread(id)
        let deadline = ContinuousClock.now + .seconds(5)
        while store.selectedThread?.id != id && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try require(store.selectedThread?.id == id, "Selected chat failed to load")
        try await Task.sleep(for: .milliseconds(500))
    }
    var checkpoints: [[String: Any]] = []
    @MainActor func capture(_ name: String) async throws {
        host.layoutSubtreeIfNeeded()
        let scroll = ChatBenchmarkModel.transcriptScrollView(in: window)
        let value: [String: Any] = ["name": name, "windowID": window.windowNumber,
            "selected": store.selectedThreadID ?? "none", "renderer": renderer,
            "visible": window.occlusionState.contains(.visible), "width": host.bounds.width,
            "clipX": scroll?.contentView.bounds.minX ?? -1, "clipY": scroll?.contentView.bounds.minY ?? -1,
            "clipWidth": scroll?.contentView.bounds.width ?? -1, "documentHeight": scroll?.documentView?.bounds.height ?? -1,
            "streamCharacters": store.cachedThread(for: a.id)?.timeline.last?.message?.text.count ?? -1,
            "unixTime": Date.now.timeIntervalSince1970]
        checkpoints.append(value)
        try require(window.occlusionState.contains(.visible), "Window is not visible")
        try save("capture-request", value)
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: output.appending(path: name + ".done").path) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(FileManager.default.fileExists(atPath: output.appending(path: name + ".done").path), "Window capture missing: " + name)
    }
    do {
        print("SWITCH_QA selecting initial chat")
        try await select(a.id)
        print("SWITCH_QA capturing initial chat")
        try await capture("a-initial")
        let source = "STREAM A START\n\n" + String((MockChatMarkdownFixtures.codeHeavy + "\n\n" + MockChatMarkdownFixtures.longMarkdown).prefix(12_000)) + "\n\nSTREAM A COMPLETE — café 👩🏽‍💻 保持"
        let characters = Array(source)
        var sent = ""
        try send(.threadTurnStartRequested)
        let streaming = Task { @MainActor in
            for offset in stride(from: 0, to: characters.count, by: 32) {
                try Task.checkCancellation()
                let chunk = String(characters[offset..<min(offset + 32, characters.count)])
                sent += chunk
                try send(.threadMessageSent, messageID: "qa-stream-reply", text: chunk)
                try await Task.sleep(for: .milliseconds(40))
            }
            var binding = store.cachedThread(for: a.id)?.session
            binding?.activeTurnID = nil
            binding?.status = "ready"
            try send(.threadSessionStatusSet, session: binding)
        }
        defer { streaming.cancel() }
        for (index, width) in [700.0, 1280, 800, 1100].enumerated() {
            try await Task.sleep(for: .milliseconds(650))
            window.setContentSize(NSSize(width: width, height: 800))
            try await Task.sleep(for: .milliseconds(350))
            try require(abs(host.bounds.width - width) < 1, "Window did not reach requested width")
            try await capture("a-resize-\(index)")
            let before = sent.count
            try await select(b.id)
            try await Task.sleep(for: .milliseconds(350))
            try require(sent.count > before, "Hidden A did not continue streaming")
            guard let cachedB = store.cachedThread(for: b.id), let cachedA = store.cachedThread(for: a.id) else { throw URLError(.unknown) }
            try require(try comparisonEncoder.encode(cachedB) == originalB, "Static B was mutated")
            try require(cachedA.timeline.last?.message?.text == sent, "Hidden A lost streamed source")
            try await capture("b-during-stream-\(index)")
            try await select(a.id)
            try require(store.selectedThread?.timeline.last?.message?.text == sent, "Returning to A lost source")
        }
        try await streaming.value
        try await Task.sleep(for: .seconds(1))
        try require(store.selectedThread?.timeline.last?.message?.text == source, "Final source differs")
        try require(store.selectedThread?.latestTurn?.state == "completed", "Working turn did not complete")
        let finalIDs = store.selectedThread?.timeline.map { $0.message?.id ?? $0.item?.id ?? "missing" } ?? []
        try require(Array(finalIDs.prefix(originalAIDs.count)) == originalAIDs && Set(finalIDs).count == finalIDs.count, "Existing identities changed or duplicated")
        try await capture("a-complete")
        try await select(b.id)
        try await capture("b-after-completion")
        try save("result", ["passed": true, "renderer": renderer, "sourceCharacters": source.count,
            "runtime": ProcessInfo.processInfo.operatingSystemVersionString, "checkpoints": checkpoints])
        print("PASS: " + renderer + " full ChatView switches/resizes; hidden stream exact, static chat untouched, final source/completion/identities preserved")
    } catch {
        print("FAIL: \(error)")
        try save("result", ["passed": false, "error": String(describing: error), "checkpoints": checkpoints])
    }
}.value
} catch {
    print("SETUP FAILURE: \(error)")
}
