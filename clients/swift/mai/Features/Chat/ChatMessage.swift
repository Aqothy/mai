import Foundation

/// A user prompt carried into a fork draft.
nonisolated struct ChatMessage {
    let turnID: String
    var entry: EntryView

    var text: String { entry.text ?? "" }
    var attachments: [Attachment]? { entry.attachments }
    var annotations: [PromptAnnotation]? { entry.annotations }
}

/// An open agent request shown above the composer.
nonisolated struct ChatRequest: Identifiable {
    let id: String
    let ask: Request
    let turnID: String?
    /// The action chosen by an answer that the agent hasn't taken yet.
    let actionID: String?

    init(open request: RequestView) {
        id = request.id
        ask = request.ask
        turnID = request.turn
        actionID = request.answering
    }
}

extension MaidTurnState {
    nonisolated var isSettled: Bool { self != .running }
}
