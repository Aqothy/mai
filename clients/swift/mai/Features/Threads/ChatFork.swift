/// What a fork made: a chat holding the agent's own fork of the
/// conversation, or a new-chat draft for an agent that can't fork, whose
/// first message hands it the conversation.
enum ChatFork {
    case thread(String)
    case draft(ForkDraft)
}
