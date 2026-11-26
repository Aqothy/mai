import CoreGraphics
import Foundation

/// One turn as the transcript shows it, copied out of `TurnView`.
nonisolated struct TranscriptTurn: Sendable {
    let id: String
    let state: MaidTurnState?
    let startedAt: Date
    let settledAt: Date?
    let error: String?
    let entries: [TranscriptEntry]
    let hasFailure: Bool

    init(_ turn: TurnView) {
        id = turn.id
        state = turn.turnState
        startedAt = turn.startedAt
        settledAt = turn.settledAt
        error = turn.error
        var failed = state == .failed
        var mapped: [TranscriptEntry] = []
        mapped.reserveCapacity(turn.entries.count)
        for entry in turn.entries {
            if !failed, entry.status == MaidItemStatus.failed.rawValue { failed = true }
            mapped.append(TranscriptEntry(entry))
        }
        entries = mapped
        hasFailure = failed
    }

    var isRunning: Bool { state == .running }

    /// "Worked for 42s", "Stopped after 3m", "Failed after 12s", or "Worked".
    var workTitle: String {
        let duration = settledAt.map { Int($0.timeIntervalSince(startedAt)) }.flatMap { $0 >= 1 ? $0 : nil }
        let text = duration.map { seconds -> String in
            let (minutes, rest) = (seconds / 60, seconds % 60)
            if minutes == 0 { return "\(rest)s" }
            return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
        }
        if state == .interrupted { return text.map { "Stopped after \($0)" } ?? "Stopped" }
        if state == .failed { return text.map { "Failed after \($0)" } ?? "Failed" }
        let base = text.map { "Worked for \($0)" } ?? "Worked"
        return hasFailure ? "\(base) · failed" : base
    }
}
