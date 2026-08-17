enum IOSNavigationRoute: Hashable {
    case newChat(workingDirectory: String?)
    case thread(String)
    case terminal(TerminalOpenRequest)
    case agentRegistry
    case sessionImport
}
