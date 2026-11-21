#if os(iOS)
enum IOSNavigationRoute: Hashable {
    case newChat(workingDirectory: String?)
    case thread(String)
    case agentRegistry
    case sessionImport
}

#endif
