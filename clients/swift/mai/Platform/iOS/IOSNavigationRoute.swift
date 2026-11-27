#if os(iOS)
enum IOSNavigationRoute: Hashable {
    case newChat(workingDirectory: String?)
    case thread(String)
    case agentRegistry
    case sessionImport

    /// The thread shown at the top of the navigation stack, or nil when the
    /// root thread list or any non-thread route is on top.
    static func selectedThreadID(in path: [IOSNavigationRoute]) -> String? {
        guard case .thread(let threadID) = path.last else { return nil }
        return threadID
    }
}

#endif
