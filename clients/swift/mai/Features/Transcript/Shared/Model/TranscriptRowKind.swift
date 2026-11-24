import CoreGraphics
import Foundation

/// What a row shows. Each case carries everything its layout needs, as
/// values, so a row can be laid out on any thread.
nonisolated enum TranscriptRowKind: Hashable, Sendable {
    /// A user prompt: one bubble (or a vertical slice of a chunked bubble),
    /// its Markdown laid out inside.
    case userMessage(source: String, position: TranscriptBlockPosition = .single)
    /// One top-level Markdown block (or bounded chunk) of an assistant message.
    case markdownBlock(MarkdownBlock, TranscriptBlockPosition)
    /// An assistant message not parsed yet; shown by estimate until its
    /// blocks replace it. Only rows far from the viewport stay like this.
    case pendingMessage(source: String)
    case thought(String)
    case activity(summary: String)
    case turnHeader(TranscriptTurnHeader)
    /// The actions under a finished turn: copying its reply (resolved lazily
    /// from the controller's turns on click) and forking from it.
    case turnActions(turnID: String, hasReply: Bool)
    /// The agent is working: the last row while a turn runs, a sparkle and
    /// a whimsical verb (the turn's header already says "Working").
    case working(phrase: String)
    /// Warnings and errors, and in Phase 1 the kinds still to be drawn
    /// natively (requests, handoffs, envelopes, stop notes, plans).
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
