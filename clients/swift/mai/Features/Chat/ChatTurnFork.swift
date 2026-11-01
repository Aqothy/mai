/// The fork actions under a settled turn.
nonisolated struct ChatTurnFork: Identifiable {
    let turnID: String
    /// The prompt that started the turn, to edit in a new chat.
    let prompt: ChatMessage?

    var id: String { "fork-\(turnID)" }
}
