import SwiftUI

/// Forks the open chat at a point, into its own agent or another, with a
/// sent prompt to edit in the fork's composer.
struct ChatForkAction {
    /// The agents other than the chat's own that it can continue in.
    let otherAgents: [ProviderChoice]
    let perform: (ChatForkPoint, String?, Message?) -> Void

    func callAsFunction(_ point: ChatForkPoint, into agentID: String? = nil, editing prompt: Message? = nil) {
        perform(point, agentID, prompt)
    }
}

extension EnvironmentValues {
    @Entry var chatFork: ChatForkAction?
}
