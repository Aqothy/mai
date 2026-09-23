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
do {
    await store.start()
    try require(store.connectionState == .connected, "Client did not connect")
    let a = "swift-queue-" + UUID().uuidString
    let b = "swift-other-" + UUID().uuidString
    try await dispatch("thread.create", b, ["title": "QA selected other chat"])
    try await dispatch("thread.start", a, [
        "providerInstanceId": "codex-app-server", "cwd": workspace,
        "title": "QA Swift queue and steering", "modelSelection": ["model": "gpt-5.6-luna"],
        "configSelections": [["optionId": "reasoning_effort", "value": "low"]],
        "message": ["text": pausePrompt(12, "FIRST_DONE")]
    ])
    store.selectThread(a)
    _ = try await waitFor(a, "queue-command-running", activeCommand)
    try require(store.selectedThread?.latestTurn?.state == "running", "Client did not observe running state")
    try await store.submitTurn(threadID: a, text: "Reply exactly QUEUED_ONE. Do not use tools.")
    try await store.submitTurn(threadID: a, text: "Reply exactly QUEUED_TWO. Do not use tools.")
    let queuedIDs = store.queuedPrompts(for: a).map(\.id)
    try require(queuedIDs.count == 2, "Expected two queued prompts")
    store.selectThread(b)
    let beforeDrain = try await snapshot(a)
    try require(messages(beforeDrain, "user").count == 1, "Queue dispatched before the active turn finished")
    try save("queue-pending", beforeDrain)
    let drained = try await waitFor(a, "queue-drained") {
        $0.latestTurn?.state == "completed" && messages($0, "user").count == 3 && store.queuedPrompts(for: a).isEmpty
    }
    let users = messages(drained, "user")
    try require(Array(users.dropFirst().map(\.id)) == queuedIDs, "Queued prompt order/identity changed")
    try require(Set(users.compactMap(\.turnID)).count == 3, "Queue did not create separate turns")
    try require(messages(drained, "assistant").suffix(2).map(\.text) == ["QUEUED_ONE", "QUEUED_TWO"], "Queued replies differ")
    try require(store.selectedThreadID == b, "Queue changed selected chat")
    try save("queue-completed", drained)
    outcomes.append("Two queued prompts waited, drained in order into separate turns, retained IDs, and did not change selected chat")
    print("PASS: real Swift client queue")

    try await store.submitTurn(threadID: a, text: pausePrompt(12, "UNSTEERED"))
    let steering = try await waitFor(a, "steering-command-running", activeCommand)
    let quoted = messages(drained, "assistant").last!
    let annotation = PromptAnnotation(id: UUID().uuidString, messageID: quoted.id, note: "Preserve this reference while steering", quote: quoted.text, role: "assistant")
    try await store.submitTurn(threadID: a, text: "Change your final reply for this running turn to exactly STEERED. No more tools are needed.", annotations: [annotation])
    let steerQueue = store.queuedPrompts(for: a)
    try require(steerQueue.count == 1, "Steering prompt was not initially queued")
    try await store.steerQueuedPrompt(threadID: a, promptID: steerQueue[0].id)
    try require(store.queuedPrompts(for: a).isEmpty, "Accepted steer stayed queued")
    let steered = try await waitFor(a, "steering-completed") {
        $0.latestTurn?.state == "completed" && $0.latestTurn?.turnID == steering.latestTurn?.turnID
    }
    let steerMessage = messages(steered, "user").last!
    try require(steerMessage.id == steerQueue[0].id && steerMessage.turnID == steering.latestTurn?.turnID, "Steer lost identity or created another turn")
    try require(steerMessage.annotations?.first?.messageID == quoted.id && steerMessage.annotations?.first?.quote == quoted.text && steerMessage.annotations?.first?.note == annotation.note, "Steer lost annotation")
    try require(messages(steered, "assistant").last?.text == "STEERED", "Provider did not apply steering")
    try require(store.selectedThreadID == b, "Steering changed selected chat")
    try require(messages(try await snapshot(b), "user").isEmpty, "Prompt leaked to selected chat")
    try save("steering-completed", steered)
    outcomes.append("Queued annotated prompt steered its own active turn, retained quote/note/message IDs, and left the other selected chat unchanged")
    print("PASS: real Swift annotated steering")

    try await store.submitTurn(threadID: a, text: pausePrompt(45, "SHOULD_BE_INTERRUPTED"))
    let running = try await waitFor(a, "interrupt-command-running", activeCommand)
    var rejectedWrongID = false
    do { try await store.interruptTurn(threadID: a, turnID: "not-the-active-turn") }
    catch { rejectedWrongID = true }
    try require(rejectedWrongID, "Wrong turn ID was accepted for interruption")
    try await store.interruptTurn(threadID: a, turnID: running.latestTurn!.turnID)
    let interrupted = try await waitFor(a, "interrupted") { $0.latestTurn?.state == "interrupted" }
    try save("interrupted", interrupted)
    try require(!activeCommand(interrupted), "Interrupted command remained active")
    try await store.submitTurn(threadID: a, text: "Reply exactly AFTER_INTERRUPT. Do not use tools.")
    let recovered = try await waitFor(a, "after-interrupt") {
        $0.latestTurn?.state == "completed" && $0.latestTurn?.turnID != interrupted.latestTurn?.turnID
    }
    try require(messages(recovered, "assistant").last?.text == "AFTER_INTERRUPT", "Next turn failed after interruption")
    try save("after-interrupt", recovered)
    outcomes.append("Wrong-turn interruption rejected; real command interrupted; subsequent turn completed normally")
    print("PASS: real Swift interruption and next turn")
    try save("client-result", outcomes)
} catch {
    try save("client-failure", ["error": String(describing: error), "completed": outcomes.joined(separator: "\n")])
    print("FAIL: \(error)")
}
rpc.onDisconnect = nil
rpc.disconnect()
