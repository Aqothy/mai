import Foundation

nonisolated struct ChatMarkdownPresentation: Equatable, Sendable {
    static let defaultStreamingThrottle: Duration = .milliseconds(50)

    var isStreaming: Bool
    var streamingThrottle: Duration
    var showsDiagnostics: Bool

    init(
        isStreaming: Bool,
        streamingThrottle: Duration = Self.defaultStreamingThrottle,
        showsDiagnostics: Bool = false
    ) {
        self.isStreaming = isStreaming
        self.streamingThrottle = max(streamingThrottle, .zero)
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
