// Prepend the setup/helper section of client-workflows.swift, before its main do block.
do {
    await store.start()
    try require(store.connectionState == .connected, "Client did not connect")
    let id = "swift-retry-" + UUID().uuidString
    try await dispatch("thread.start", id, [
        "providerInstanceId": "codex-app-server", "cwd": workspace,
        "title": "QA Swift provider crash and retry", "modelSelection": ["model": "gpt-5.6-luna"],
        "configSelections": [["optionId": "reasoning_effort", "value": "low"]],
        "message": ["text": pausePrompt(12, "RETRIED_OK")]
    ])
    store.selectThread(id)
    let running = try await waitFor(id, "before-crash", activeCommand)
    try save("before-crash", running)
    let user = messages(running, "user").first!
    // The harness checks this thread's directory/state and verifies that the
    // recorded provider PID is still a direct child of its own daemon.
    try save("crash-provider-request", ["threadId": id])
    let failed = try await waitFor(id, "provider-crash", seconds: 15) { $0.latestTurn?.state == "error" }
    try save("failed-turn", failed)
    try require(!activeCommand(failed), "Failed turn retained a running command")
    try require(store.failedTurnID(for: id) == running.latestTurn?.turnID, "Swift did not expose failed turn for Retry")
    _ = try await rpc.startProvider("codex-app-server")
    try await store.retryFailedTurn(threadID: id)
    let retried = try await waitFor(id, "retry-completed") {
        $0.latestTurn?.state == "completed" && $0.latestTurn?.turnID != failed.latestTurn?.turnID
    }
    let users = messages(retried, "user")
    try require(users.count == 1 && users[0].id == user.id && users[0].text == user.text, "Retry duplicated or changed the original prompt")
    try require(users[0].turnID == retried.latestTurn?.turnID, "Retry did not rebind the original prompt")
    try require(messages(retried, "assistant").last?.text == "RETRIED_OK", "Retry did not complete normally")
    try require(store.failedTurnID(for: id) == nil, "Retry left a stale failed state")
    try save("retry-completed", retried)
    outcomes.append("Provider crash settled the active turn; Swift Retry preserved one original prompt/ID, used a fresh turn, and completed")
    try save("client-result", outcomes)
    print("PASS: real Swift provider crash and retry")
} catch {
    try save("client-failure", ["error": String(describing: error), "completed": outcomes.joined(separator: "\n")])
    print("FAIL: \(error)")
}
rpc.onDisconnect = nil
rpc.disconnect()
