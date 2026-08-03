#if os(iOS)
enum IOSNavigationRoute: Hashable {
    case newChat
    case thread(String)
    case agentRegistry
    case sessionImport
}
#endif
