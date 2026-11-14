/// The platform's transcript document and the controller that keeps its
/// scroll position, under the names the shared timeline uses.
#if os(macOS)
    typealias ChatTranscriptScrollDocument = any ChatMacScrollDocument
    typealias ChatTranscriptScrollPositionPreserver = ChatMacScrollPositionPreserver
#else
    typealias ChatTranscriptScrollDocument = any ChatIOSScrollDocument
    typealias ChatTranscriptScrollPositionPreserver = ChatIOSScrollPositionPreserver
#endif
