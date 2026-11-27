/// Where a fork of a chat ends. The daemon keeps only turns the agent has, so
/// a running turn or one that never reached the agent is left out.
enum ChatForkPoint: Equatable {
    /// Through the last settled turn.
    case latest
    /// Through this turn.
    case through(turnID: String)
    /// Up to the turn before this one, as when editing its prompt.
    case before(turnID: String)
}
