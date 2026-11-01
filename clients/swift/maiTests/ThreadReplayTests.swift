import Foundation
import Testing
@testable import mai

/// What a real daemon sent, folded the way the client folds it, equals the
/// thread read back after a restart rebuilt it from the provider's native
/// session.
struct ThreadReplayTests {
    @Test @MainActor
    func forkFoldsToWhatTheNativeSessionRebuilds() throws {
        let capture = try Capture.decode(ThreadReplayFixtures.fork)
        let live = capture.folded()

        #expect(shape(live.turns) == shape(ThreadDetail(capture.reload).turns))
        #expect(live.status == .idle)
        #expect(live.turns.count == 3)
        // The copied turns keep the prompt's comment.
        #expect(live.turns[0].entries.first?.annotations?.map(\.quote) == ["an earlier answer"])
        let answer = try #require(live.turns.last)
        #expect(answer.entries.map(\.itemKind) == [.envelope, .userMessage, .reasoning, .assistantMessage])
        #expect(answer.entries.first?.envelopeKind == .handoff)
        #expect(answer.entries.last?.text == "ok two")
        let rows = ChatTimelineLayout.rows(sections: ChatTimelineLayout.sections(turns: live.turns), expandedSectionIDs: [])
        #expect(rows.filter { if case .handoff = $0 { true } else { false } }.count == 1)
    }

    @Test @MainActor
    func subagentReportWakesATurnOfItsOwnWithoutAPrompt() throws {
        let capture = try Capture.decode(ThreadReplayFixtures.handback)
        let live = capture.folded()

        #expect(shape(live.turns) == shape(ThreadDetail(capture.reload).turns))
        #expect(live.status == .idle)
        #expect(live.turns.map(\.startedBy) == [MaidStartedBy.delivery.rawValue, MaidStartedBy.provider.rawValue])
        #expect(!live.turns[1].entries.contains { $0.itemKind == .userMessage })
        #expect(live.turns[1].entries.last?.text == "sub")
        let child = try #require(live.children.first)
        #expect(live.children.count == 1)
        #expect(child.originKind == .native && !child.origin.acceptsInput && child.origin.parent == live.id)
    }

    private struct Capture: Decodable {
        let snapshot: ThreadSnapshot
        let events: [ThreadEvent]
        let reload: ThreadSnapshot

        static func decode(_ base64: String) throws -> Capture {
            let compressed = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
            let data = try (compressed as NSData).decompressed(using: .zlib) as Data
            return try newJSONDecoder().decode(Capture.self, from: data)
        }

        func folded() -> ThreadDetail {
            var detail = ThreadDetail(snapshot)
            for event in events {
                _ = detail.apply(event)
            }
            return detail
        }
    }

    private struct EntryShape: Equatable {
        let ref, kind: String
        let status, text: String?
        let envelope: String?
        let quotes: [String]
    }

    private struct TurnShape: Equatable {
        let id, state: String
        let entries: [EntryShape]
    }

    private func shape(_ turns: [TurnView]) -> [TurnShape] {
        turns.map { turn in
            TurnShape(id: turn.id, state: turn.state, entries: turn.entries.map { entry in
                EntryShape(
                    ref: entry.ref, kind: entry.kind, status: entry.status, text: entry.text,
                    envelope: entry.envelope?.kind, quotes: (entry.annotations ?? []).map(\.quote))
            })
        }
    }
}
