import Observation

@Observable
final class ChatScrollState {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    struct BottomScrollRequest: Equatable {
        var count = 0
        var animated = false
    }

    var isNearBottom = true
    private(set) var bottomScrollRequest = BottomScrollRequest()

    func requestScrollToBottom(animated: Bool = false) {
        bottomScrollRequest = BottomScrollRequest(
            count: bottomScrollRequest.count + 1,
            animated: animated
        )
    }

    func reset() {
        isNearBottom = true
    }
}
