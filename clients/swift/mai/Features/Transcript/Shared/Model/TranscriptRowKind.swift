import Foundation

/// What a row shows. Each case carries everything its layout needs, as
/// values, so a row can be laid out on any thread. One row per top-level
/// block, with no slicing (`REDESIGN.md §1, §7 R2`).
nonisolated enum TranscriptRowKind: Hashable, Sendable {
    /// A user prompt: one bubble, its parsed Markdown blocks laid out inside.
    case userMessage([MarkdownBlock])
    /// One top-level Markdown block of an assistant message.
    case markdownBlock(MarkdownBlock, TranscriptBlockPosition)
    /// Reasoning, in muted text: parsed Markdown blocks laid out as one text.
    case thought([MarkdownBlock])
    /// A message (user, assistant, or reasoning) not parsed yet; shown by O(1)
    /// estimate until its off-main parse replaces it.
    case pendingMessage(TranscriptMessage, source: String)
    case activity(summary: String)
    case turnHeader(TranscriptTurnHeader)
    /// The actions under a finished turn: copying its reply (resolved lazily
    /// from the controller's turns on click) and forking from it.
    case turnActions(turnID: String, hasReply: Bool)
    /// The agent is working: the last row while a turn runs, a sparkle and
    /// a whimsical verb (the turn's header already says "Working").
    case working(phrase: String)
    /// Warnings, errors, notices, plans, handoffs, and envelopes.
    case notice(title: String, text: String?)
}

nonisolated extension TranscriptRowKind {
    /// Whether the row's text takes part in selection: message text of both
    /// roles, thoughts and notices; never chrome such as headers, actions or
    /// the working row (PLAN Q2).
    var isSelectable: Bool {
        switch self {
        case .userMessage, .markdownBlock, .pendingMessage, .thought, .notice: true
        case .activity, .turnHeader, .turnActions, .working: false
        }
    }
}
