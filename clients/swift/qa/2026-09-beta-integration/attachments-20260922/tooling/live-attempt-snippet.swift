try await Task { @MainActor in
// Run using Xcode RunCodeSnippet in ThreadStore.swift's context.
// Replace /Users/aqothy/Library/Containers/com.anthonyqiu.mai/Data/tmp/mai-live-attachments-20260923-b with the isolated check-provider.mjs client-phase directory.
let output = URL(fileURLWithPath: "/Users/aqothy/Library/Containers/com.anthonyqiu.mai/Data/tmp/mai-live-attachments-20260923-b")
let ready = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appending(path: "ready.json"))) as! [String: Any]
let endpoint = URL(string: ready["endpoint"] as! String)!
let workspace = ready["workspace"] as! String
let rpc = RPCClient(endpoint: endpoint)
let store = ThreadStore(rpc: rpc)
var outcomes: [String] = []
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "WorkflowQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func save<Value: Encodable>(_ name: String, _ value: Value) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: output.appending(path: name + ".json"))
}
@MainActor func dispatch(_ type: String, _ id: String, _ fields: [String: Any] = [:]) async throws {
    var data = fields
    data["type"] = type
    data["threadId"] = id
    data["commandId"] = UUID().uuidString
    let command = try newJSONDecoder().decode(Command.self, from: JSONSerialization.data(withJSONObject: data))
    _ = try await rpc.dispatchCommand(command)
}
func snapshot(_ id: String) async throws -> Thread {
    let item = try await rpc.subscribeThread(SubscribeThreadInput(threadID: id))
    guard let thread = item.snapshot?.thread else { throw NSError(domain: "WorkflowQA", code: 2) }
    return thread
}
func waitFor(_ id: String, _ label: String, seconds: TimeInterval = 100, _ predicate: (Thread) -> Bool) async throws -> Thread {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        let thread = try await snapshot(id)
        if predicate(thread) { return thread }
        if thread.latestTurn?.state == "error" {
            try save(label + "-error", thread)
            throw NSError(domain: "WorkflowQA", code: 3, userInfo: [NSLocalizedDescriptionKey: thread.latestTurn?.error ?? label])
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    try save(label + "-timeout", try await snapshot(id))
    throw NSError(domain: "WorkflowQA", code: 4, userInfo: [NSLocalizedDescriptionKey: label + " timed out"])
}
func messages(_ thread: Thread, _ role: String) -> [Message] {
    thread.timeline.compactMap(\.message).filter { $0.role == role }
}
func activeCommand(_ thread: Thread) -> Bool {
    thread.timeline.compactMap(\.item).contains {
        $0.kind == "command_execution" && $0.status == "in_progress" && $0.turnID == thread.latestTurn?.turnID
    }
}
func pausePrompt(_ seconds: Int, _ marker: String) -> String {
    "This is a harmless timing QA in the disposable current directory. Use the terminal tool to run exactly python3 -c 'import time; time.sleep(\(seconds)); print(\"PAUSE_DONE\")'. Use ordinary sandbox execution; do not request extra permissions, access files, use network, or run another command. After it finishes, reply with exactly \(marker)."
}
// Prepend the setup/helpers from workflows-20260922/client-workflows.swift.
// Run in ComposerAttachments.swift's context on My Mac with the isolated daemon.
let suiteName = "mai-attachment-qa-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suiteName)!
let draftStore = ThreadDraftStore(defaults: defaults)
let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
var arguments = originalArguments
arguments["ChatBenchmarkUseList"] = false
UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
let host = NSHostingView(rootView: ChatView(store: store, draftStore: draftStore, openThread: nil).id("native"))
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.title = "mai live image QA"
window.contentView = host
window.orderFront(nil)
defer {
    window.orderOut(nil)
    window.close()
    defaults.removePersistentDomain(forName: suiteName)
    UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
    rpc.onDisconnect = nil
    rpc.disconnect()
}
@MainActor func captureChat(_ name: String, color: String) async throws {
    // Decode and native preparation run asynchronously. Only accept a capture
    // that contains substantial pixels of the actual uploaded fixture.
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var matches = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if c.alphaComponent > 0.9 && (color == "red" ? c.redComponent > 0.65 && c.blueComponent < 0.35 : c.blueComponent > 0.65 && c.redComponent < 0.35) { matches += 1 }
                }
            }
            if matches > 1000, let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: output.appending(path: name + ".png"))
                try save(name, ["matchingColorSamples": matches, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh])
                return
            }
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw NSError(domain: "AttachmentQA", code: 4, userInfo: [NSLocalizedDescriptionKey: "Uploaded image was not visible in " + name])
}
do {
    print("STAGE: connect")
    await store.start()
    try require(store.connectionState == .connected, "Client did not connect")
    let images = ComposerAttachmentsModel()
    var errors: [String] = []
    images.reportError = { errors.append($0) }
    await images.addImages(from: [output.appending(path: "red.png"), output.appending(path: "blue.png")])
    let deadline = Date().addingTimeInterval(10)
    while images.attachments.contains(where: \.isProcessing) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    try require(errors.isEmpty && images.attachments.count == 2 && !images.attachments.contains(where: \.isProcessing), "Composer failed to prepare fixtures")
    let red = images.attachments[0].attachment!, blue = images.attachments[1].attachment!
    let attachmentJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(red))
    let id = "swift-live-image-" + UUID().uuidString
    print("STAGE: image-only send")
    try await dispatch("thread.start", id, [
        "providerInstanceId": "codex-app-server", "cwd": workspace,
        "title": "QA image-only and mixed prompt", "modelSelection": ["model": "gpt-5.6-luna"],
        "configSelections": [["optionId": "reasoning_effort", "value": "low"]],
        "message": ["text": "", "attachments": [attachmentJSON]]
    ])
    print("STAGE: image-only accepted")
    store.selectThread(id)
    let imageOnly = try await waitFor(id, "image-only-completed") { $0.latestTurn?.state == "completed" }
    try require(messages(imageOnly, "user").count == 1 && messages(imageOnly, "user")[0].text.isEmpty, "Image-only prompt acquired unexpected text")
    try require(messages(imageOnly, "user")[0].attachments?.first?.data == red.data, "Image-only upload bytes changed")
    try require(!messages(imageOnly, "assistant").isEmpty, "Image-only turn had no assistant reply")
    try save("image-only-completed", imageOnly)
    print("STAGE: image-only completed")
    try await captureChat("image-only-native", color: "red")
    outcomes.append("Image-only prompt passed the composer, actual Swift RPC, daemon and Codex and rendered the original red image in the native transcript")
    let prompt = "Inspect the attached image. Reply with only its dominant color as one lowercase word. Do not use tools."
    try await store.submitTurn(threadID: id, text: prompt, attachments: [blue])
    let mixed = try await waitFor(id, "mixed-image-completed") { $0.latestTurn?.state == "completed" && $0.latestTurn?.turnID != imageOnly.latestTurn?.turnID }
    let sent = messages(mixed, "user").last!
    try require(sent.text == prompt && sent.attachments?.first?.data == blue.data, "Mixed prompt lost text or image bytes")
    try require(messages(mixed, "assistant").last?.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "blue", "Codex did not identify the uploaded blue image")
    try save("mixed-image-completed", mixed)
    try await captureChat("mixed-image-native", color: "blue")
    arguments["ChatBenchmarkUseList"] = true
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    host.rootView = ChatView(store: store, draftStore: draftStore, openThread: nil).id("list")
    try await captureChat("mixed-image-list", color: "blue")
    outcomes.append("Text plus image preserved exact text/bytes, Codex identified blue, and both native and List transcripts rendered the blue attachment")
    try save("client-result", outcomes)
    print("PASS: real image-only and mixed-image Codex turns, native and List rendering")
} catch {
    try save("client-failure", ["error": String(describing: error), "completed": outcomes.joined(separator: "\n")])
    print("FAIL: \(error)")
}

}.value
