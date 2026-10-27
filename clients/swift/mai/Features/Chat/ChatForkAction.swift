import SwiftUI

/// Starts a fork of the open chat at a point, into its own agent or another,
/// as a new-chat draft, with a sent prompt to edit in its composer.
struct ChatForkAction {
    /// The agents other than the chat's own that it can continue in.
    let otherAgents: [ProviderChoice]
    let perform: (ChatForkPoint, String?, ChatMessage?) -> Void

    func callAsFunction(_ point: ChatForkPoint, into agentID: String? = nil, editing prompt: ChatMessage? = nil) {
        perform(point, agentID, prompt)
    }
}

extension EnvironmentValues {
    @Entry var chatFork: ChatForkAction?
}
