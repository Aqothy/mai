// Run in ThreadSession.swift through Xcode MCP on each platform.
// Replace QA_FIXTURE_BASE64 with the base64 encoding of pipeline.json.
try await Task { @MainActor in
    struct Value: Decodable, Equatable {
        let kind: String
        let id: String
        let status: String
        let text: String
    }
    struct Fixture: Decodable {
        let initial: Thread
        let events: [Event]
        let live: Thread
        let reload: Thread
        let expected: [Value]
    }
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "ReasoningPipelineQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
    @MainActor func values(_ thread: Thread) -> [Value] {
        thread.timeline.compactMap { entry in
            if let item = entry.item {
                return Value(kind: item.kind, id: item.id, status: item.status ?? "", text: ChatTimelineLayout.reasoningText(item) ?? "")
            }
            if let message = entry.message {
                return Value(kind: message.role, id: message.id, status: "", text: message.text)
            }
            return nil
        }
    }
    let data = Data(base64Encoded: "QA_FIXTURE_BASE64")!
    let fixture = try newJSONDecoder().decode(Fixture.self, from: data)
    var session = ThreadSession(thread: fixture.initial)
    var thoughtText: [String: String] = [:]
    var deltaCount = 0
    var completedCount = 0
    for event in fixture.events {
        try require(session.apply(event).applied, "Event was not applied: \(event.eventID)")
        if let item = event.payload.item, item.itemKind == .reasoning {
            if let delta = item.textDelta {
                thoughtText[item.id, default: ""] += delta
                deltaCount += 1
            } else if let text = (item.payload?.value as? [String: Any])?["text"] as? String {
                thoughtText[item.id] = text
            }
            let projected = session.thread?.timeline.compactMap(\.item).first { $0.id == item.id }
            try require(projected != nil, "Missing thought after event")
            try require(projected.flatMap(ChatTimelineLayout.reasoningText) == thoughtText[item.id], "Live thought differs from the exact wire text")
            if item.itemStatus == .completed {
                completedCount += 1
                try require(projected?.itemStatus == .completed, "Thought did not settle")
            }
        }
        try require(!session.apply(event).applied, "Duplicate sequence was accepted")
    }
    guard let final = session.thread else { throw NSError(domain: "ReasoningPipelineQA", code: 2) }
    try require(deltaCount == 3 && completedCount == 3, "Unexpected fixture coverage")
    try require(values(final) == fixture.expected, "Client final timeline differs")
    try require(values(fixture.live) == fixture.expected, "Server live snapshot differs")
    try require(values(fixture.reload) == fixture.expected, "Provider history reload differs")
    try require(final.latestTurn?.state == "completed" && !session.isProtected, "Completed turn retains activity")
    print("PASS: \(fixture.events.count) server events, 3 live thought checkpoints, 3 authoritative completions, exact 5-entry timeline and stable identities after reload, duplicate sequences rejected, activity cleared")
}.value
