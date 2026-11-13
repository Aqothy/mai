import Foundation

/// Bridges the gap between a turn finishing and its settled presentation
/// being ready. Switching a just-finished message to the settled path with
/// cold caches parses and lays out its entire text synchronously on the main
/// thread in one frame; instead the message keeps its streaming presentation
/// until the preparation task has primed everything off the main actor.
///
/// Plain non-observable storage: `body` records the live turn here without
/// triggering another invalidation.
final class ChatStreamingContinuity {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    private var lastStreamingTurnID: String?
    private var preparedSettledTurnID: String?

    /// Records the live turn and answers which finished turn should keep its
    /// streaming presentation. Lingers only for the latest turn, and only
    /// until its settled preparation completes; any other transition (thread
    /// restored idle, a newer turn already running) uses the settled path.
    func settlingTurnID(
        streamingTurnID: String?,
        latestTurnID: String?
    ) -> String? {
        if let streamingTurnID {
            lastStreamingTurnID = streamingTurnID
            return nil
        }
        guard let lastStreamingTurnID,
            lastStreamingTurnID == latestTurnID,
            lastStreamingTurnID != preparedSettledTurnID
        else { return nil }
        return lastStreamingTurnID
    }

    func noteSettledPreparation(turnID: String) {
        preparedSettledTurnID = turnID
    }
}
