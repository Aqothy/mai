/// A new chat that continues another, waiting for its first message: the
/// daemon makes the fork only when it is sent, so an abandoned fork leaves
/// nothing behind.
nonisolated struct ForkDraft: Codable, Equatable {
    let sourceThreadID: String
    let sourceTitle: String
    /// The last turn the fork keeps; nil keeps none, a fresh start with the
    /// chat's agent and folders.
    let throughTurnID: String?
    /// The agent's own session forks, with its settings; otherwise `agentID`
    /// starts a session of its own, and the composer holds a summary of the
    /// conversation to send with the first message.
    let native: Bool
    /// The agent the new chat starts with.
    let agentID: String?
    let cwd: String
    let additionalDirectories: [String]
}
