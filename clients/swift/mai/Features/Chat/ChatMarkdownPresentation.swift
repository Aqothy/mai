nonisolated struct ChatMarkdownPresentation: Equatable, Sendable {
    var isStreaming: Bool
    var showsDiagnostics: Bool

    init(
        isStreaming: Bool,
        showsDiagnostics: Bool = false
    ) {
        self.isStreaming = isStreaming
        self.showsDiagnostics = showsDiagnostics
    }

    static func timelineMessage(
        role: String,
        turnID: String?,
        streamingTurnID: String?
    ) -> Self {
        Self(
            isStreaming: role == MaidMessageRole.assistant.rawValue
                && streamingTurnID.map { $0 == turnID } == true
        )
    }
}
