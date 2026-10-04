import Foundation
import Testing
@testable import mai

struct ChatProviderReplayTests {
    @Test @MainActor
    func reasoningWireAndReloadPreserveTextAndIdentities() async throws {
        struct Value: Decodable, Equatable {
            let kind: String
            let id: String
            let status: String
            let text: String
        }
        struct Fixture: Decodable {
            let initial: mai.Thread
            let events: [Event]
            let live: mai.Thread
            let reload: mai.Thread
            let expected: [Value]
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "ReasoningPipelineQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        @MainActor func values(_ thread: mai.Thread) -> [Value] {
            thread.timeline.compactMap { entry in
                if let item = entry.item {
                    return Value(kind: item.kind, id: item.id, status: item.status, text: ChatTimelineLayout.reasoningText(item) ?? "")
                }
                if let message = entry.message {
                    return Value(kind: message.role, id: message.id, status: "", text: message.text)
                }
                return nil
            }
        }
        let data = try inflate(ChatProviderReplayFixtures.reasoningPipeline)
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
    }

    @Test @MainActor
    func snapshotReplayRetainsAnnotationsAcrossRestartForkAndRuntime() async throws {
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
        func values(_ thread: mai.Thread) -> [MessageValue] {
            thread.timeline.compactMap(\.message).map { message in
                MessageValue(id: message.id, role: message.role, text: message.text,
                    annotations: (message.annotations ?? []).map {
                        AnnotationValue(id: $0.id, messageID: $0.messageID, role: $0.role, quote: $0.quote, note: $0.note)
                    })
            }
        }
        let json = try inflate(ChatProviderReplayFixtures.annotationSnapshots)
        let threads = try newJSONDecoder().decode([mai.Thread].self, from: json)
        try require(threads.count == 5, "Incomplete live/restart/fork/runtime fixture")
        // Establish the baseline independently of the generated model decoder,
        // so consistently losing optional annotation fields cannot pass.
        let rawThreads = try #require(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        let rawThread = try #require(rawThreads.first)
        let timeline = try #require(rawThread["timeline"] as? [[String: Any]])
        let expected = try timeline.compactMap { entry -> MessageValue? in
            guard let message = entry["message"] as? [String: Any] else { return nil }
            let annotations = try (message["annotations"] as? [[String: Any]] ?? []).map { annotation in
                AnnotationValue(
                    id: try #require(annotation["id"] as? String),
                    messageID: annotation["messageId"] as? String,
                    role: annotation["role"] as? String,
                    quote: try #require(annotation["quote"] as? String),
                    note: annotation["note"] as? String
                )
            }
            return MessageValue(
                id: try #require(message["id"] as? String),
                role: try #require(message["role"] as? String),
                text: try #require(message["text"] as? String),
                annotations: annotations
            )
        }
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
    }

    @MainActor private func inflate(_ base64: String) throws -> Data {
        let data = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        return try (data as NSData).decompressed(using: .zlib) as Data
    }
}
