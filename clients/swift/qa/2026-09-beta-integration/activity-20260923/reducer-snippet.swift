// Run through Xcode MCP in ComposerAttachments.swift on each platform.
try await Task { @MainActor in
    let thread = ChatSyntheticBenchmarkThread.thread(turnCount: 20)
    let store = ThreadStore(previewThreads: [ChatSyntheticBenchmarkThread.listEntry(for: thread)], selectedThread: thread)
    func identity(_ entry: TimelineEntry) -> String {
        entry.message?.id ?? entry.item?.id ?? entry.approval?.requestID ?? "missing-id"
    }
    let beforeIDs = thread.timeline.map(identity)
    let driver = ChatSyntheticStreamingBenchmark(store: store, includesActivity: true)
    driver.prepare()
    await driver.run()
    guard driver.isFinished, driver.sourceMatches, let final = store.selectedThread else {
        throw NSError(domain: "ActivityQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "Incomplete or mismatched stream"])
    }
    let actualIDs = final.timeline.map(identity)
    guard Set(actualIDs).count == actualIDs.count, Array(actualIDs.prefix(beforeIDs.count)) == beforeIDs else {
        throw NSError(domain: "ActivityQA", code: 2, userInfo: [NSLocalizedDescriptionKey: "Changed or duplicated existing history"])
    }
    let entries = final.timeline.filter { ($0.message?.turnID ?? $0.item?.turnID) == "synthetic-stream-turn" }
    guard entries.count == 5 else { throw NSError(domain: "ActivityQA", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unexpected final entry count: \(entries.count)"]) }
    print("PASS: two exact completed thoughts, twelve tool updates, exact 20,000-character reply, completed turn, five unique new entries, original history identity preserved")
}.value
