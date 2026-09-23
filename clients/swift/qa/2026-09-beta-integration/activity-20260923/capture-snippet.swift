// Run in ComposerAttachments.swift with Xcode RunCodeSnippet on My Mac.
// Substitute a new QA_OUTPUT directory and RENDERER (native or list).
try await Task { @MainActor in
    let output = URL(fileURLWithPath: "QA_OUTPUT")
    let renderer = "RENDERER"
    let activationPolicy = NSApplication.shared.activationPolicy()
    NSApplication.shared.setActivationPolicy(.regular)
    defer { NSApplication.shared.setActivationPolicy(activationPolicy) }
    let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    var arguments = original
    arguments["ChatBenchmarkUseList"] = renderer == "list"
    arguments["ChatAutoBenchmark"] = "activity-capture"
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    let suite = "mai-activity-qa-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer {
        defaults.removePersistentDomain(forName: suite)
        UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
    }
    let thread = ChatSyntheticBenchmarkThread.thread(turnCount: 20)
    let store = ThreadStore(previewThreads: [ChatSyntheticBenchmarkThread.listEntry(for: thread)], selectedThread: thread)
    let drafts = ThreadDraftStore(defaults: defaults)
    let host = NSHostingView(rootView: ChatView(store: store, draftStore: drafts, openThread: nil))
    host.sizingOptions = []
    let window = NSWindow(contentRect: NSRect(x: 100, y: 50, width: 1000, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "mai activity capture " + renderer
    window.contentView = host
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.level = .floating
    NSApplication.shared.unhide(nil)
    NSApplication.shared.activate()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.close() }
    func save(_ name: String, _ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appending(path: name + ".json"))
    }
    func waitForMarker(_ marker: String) async throws {
        let deadline = Date().addingTimeInterval(45)
        while !FileManager.default.fileExists(atPath: output.appending(path: marker).path) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        if !FileManager.default.fileExists(atPath: output.appending(path: marker).path) {
            throw NSError(domain: "ActivityQA", code: 1, userInfo: [NSLocalizedDescriptionKey: marker + " did not arrive"])
        }
    }
    do {
        try await Task.sleep(for: .seconds(3))
        let frame = window.frame
        try save("ready", ["windowID": window.windowNumber, "pid": ProcessInfo.processInfo.processIdentifier,
                           "renderer": renderer, "width": frame.width, "height": frame.height,
                           "native": ChatTranscriptConfiguration.usesNativeMacTranscript,
                           "appHidden": NSApplication.shared.isHidden,
                           "activationPolicy": NSApplication.shared.activationPolicy().rawValue,
                           "isOnActiveSpace": window.isOnActiveSpace,
                           "isVisible": window.isVisible,
                           "visible": window.occlusionState.contains(.visible),
                           "readyAt": Date.now.timeIntervalSince1970])
        try await waitForMarker("recording")
        let driver = ChatSyntheticStreamingBenchmark(store: store, includesActivity: true)
        let started = Date.now.timeIntervalSince1970
        driver.prepare()
        try await Task.sleep(for: .milliseconds(500))
        await driver.run()
        let visible = window.occlusionState.contains(.visible)
        let sameFrame = window.frame == frame
        try save("done", ["sourceMatches": driver.sourceMatches, "completed": driver.isFinished,
                          "startedAt": started, "completedAt": Date.now.timeIntervalSince1970,
                          "visible": visible, "unchangedFrame": sameFrame])
        try await waitForMarker("captured")
        if !driver.sourceMatches || !driver.isFinished || !visible || !sameFrame {
            throw NSError(domain: "ActivityQA", code: 2, userInfo: [NSLocalizedDescriptionKey: "Activity source, completion, visibility or viewport failed"])
        }
        print("PASS: " + renderer + " actual activity stream window, exact thoughts/tool/reply and completion")
    } catch {
        try save("failure", ["error": String(describing: error)])
        print("FAIL: \(error)")
    }
}.value
