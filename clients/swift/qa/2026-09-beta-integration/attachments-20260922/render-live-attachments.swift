// Run using Xcode RunCodeSnippet in ThreadStore.swift's context.
// Replace QA_OUTPUT with the isolated check-provider.mjs client-phase directory.
let output = URL(fileURLWithPath: "QA_OUTPUT")
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
try await Task { @MainActor in
let suite = "mai-image-render-qa-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
let drafts = ThreadDraftStore(defaults: defaults)
let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
defer { defaults.removePersistentDomain(forName: suite); UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain); rpc.onDisconnect = nil; rpc.disconnect() }
await store.start()
try require(store.connectionState == .connected, "Disconnected")
store.selectThread("SOURCE_THREAD_ID")
let until = Date().addingTimeInterval(10)
while store.selectedThread == nil && Date() < until { try await Task.sleep(for: .milliseconds(100)) }
try require(store.selectedThread != nil, "No selected thread")
for mode in ["native", "list"] {
    var args = original
    args["ChatBenchmarkUseList"] = mode == "list"
    UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    let host = NSHostingView(rootView: ChatView(store: store, draftStore: drafts, openThread: nil))
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.title = "mai attachment render QA " + mode
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); window.close() }
    try await Task.sleep(for: .seconds(3))
    host.layoutSubtreeIfNeeded()
    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: output.appending(path: mode + "-cache.png"))
    }
    var geometry: [[String: String]] = []
    func inspect(_ view: NSView, depth: Int) {
        geometry.append(["type": String(describing: type(of: view)), "frame": NSStringFromRect(view.frame), "bounds": NSStringFromRect(view.bounds), "depth": String(depth)])
        for child in view.subviews { inspect(child, depth: depth + 1) }
    }
    inspect(host, depth: 0)
    try save(mode + "-geometry", geometry)
    try save(mode + "-ready", ["windowID": window.windowNumber, "native": ChatTranscriptConfiguration.usesNativeMacTranscript ? 1 : 0])
    let deadline = Date().addingTimeInterval(45)
    while !FileManager.default.fileExists(atPath: output.appending(path: mode + "-captured").path) && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
    try require(FileManager.default.fileExists(atPath: output.appending(path: mode + "-captured").path), "Capture did not finish")
    print("Captured " + mode)
}
}.value
