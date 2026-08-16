enum IOSNavigationRoute: Hashable {
    case newChat
    case thread(String)
    case terminal(TerminalOpenRequest)
    case agentRegistry
    case sessionImport
}
