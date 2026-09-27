// Execute in ThreadSession.swift through Xcode MCP on Mac and iOS 18.6.
// Substitute the base64 encoding of client-annotation-fixture.deflate.
try await Task { @MainActor in
    struct AnnotationValue: Equatable {
        let id: String
        let messageID: String?
        let role: String?
        let quote: String
        let note: String?
    }
    struct MessageValue: Equatable {
        let id: String
        let role: String
        let text: String
        let annotations: [AnnotationValue]
    }
    func require(_ condition: Bool, _ detail: String) throws {
        guard condition else {
            throw NSError(domain: "AnnotationReplayQA", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }
    func values(_ thread: Thread) -> [MessageValue] {
        thread.timeline.compactMap(\.message).map { message in
            MessageValue(id: message.id, role: message.role, text: message.text,
                annotations: (message.annotations ?? []).map {
                    AnnotationValue(id: $0.id, messageID: $0.messageID, role: $0.role, quote: $0.quote, note: $0.note)
                })
        }
    }
    guard let data = Data(base64Encoded: "QA_FIXTURE_BASE64") else {
        throw NSError(domain: "AnnotationReplayQA", code: 2)
    }
    let json = try (data as NSData).decompressed(using: .zlib) as Data
    let threads = try newJSONDecoder().decode([Thread].self, from: json)
    try require(threads.count == 5, "Incomplete live/restart/fork/runtime fixture")
    let expected = values(threads[0])
    try require(expected.filter { !$0.annotations.isEmpty }.count == 5, "Missing annotation-only, repeated or steering prompt")
    try require(expected.contains { $0.text.isEmpty && !$0.annotations.isEmpty }, "Missing annotation-only prompt")
    for thread in threads {
        let session = ThreadSession(thread: thread)
        try require(!session.isProtected, "Completed replay retains activity")
        try require(values(thread) == expected, "Decoded message IDs/text/annotation cards differ")
        let messages = thread.timeline.compactMap(\.message)
        let ids = Set(messages.map(\.id))
        try require(ids.count == messages.count, "Duplicate messages")
        let rows = ChatTimeline.renderRows(messages.map(ChatTimelineRowModel.message), streamingTurnID: nil, segmentCache: session.markdownSegmentCache)
        for message in messages where !(message.annotations ?? []).isEmpty {
            let retained = rows.compactMap { row -> Message? in
                if case .standard(.message(let value)) = row, value.id == message.id { return value }
                return nil
            }
            try require(retained.count == 1 && retained.first?.annotations?.count == message.annotations?.count, "Annotation cards lost before rendering")
            try require((message.annotations ?? []).allSatisfy { $0.messageID.map(ids.contains) ?? false }, "Quote reference points outside this chat")
        }
    }
    print("PASS: five live/restart/fork/runtime snapshots, five annotation cards each, exact prompt/quote/note/message identities, all references resolve, standard annotation renderer retained, activity cleared")
}.value
