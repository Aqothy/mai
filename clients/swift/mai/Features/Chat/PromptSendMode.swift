/// How a prompt sent while the agent is working reaches it. An idle chat
/// starts a turn with the prompt either way.
enum PromptSendMode {
    /// Waits for the running turn to end, then runs as the next turn.
    case queue
    /// Joins the running turn, at the next point the agent takes input.
    case steer

    /// What Return and a tap on Send do. Command-Return on macOS, and the
    /// Send button's long-press menu on iOS, offer the other mode.
    static let standard = PromptSendMode.queue

    var alternate: PromptSendMode {
        switch self {
        case .queue: .steer
        case .steer: .queue
        }
    }
}
