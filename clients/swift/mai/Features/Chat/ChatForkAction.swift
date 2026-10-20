import SwiftUI

/// Forks the open chat at a point, with a sent prompt to edit in the fork's
/// composer.
struct ChatForkAction {
    let perform: (ChatForkPoint, Message?) -> Void

    func callAsFunction(_ point: ChatForkPoint, editing prompt: Message? = nil) {
        perform(point, prompt)
    }
}

extension EnvironmentValues {
    @Entry var chatFork: ChatForkAction?
}
