import Foundation

struct ChatTimelineHistoryLoadTrigger: Equatable {
    let request: Int
    let isAwaitingInitialBottom: Bool
    let oldestSectionID: String?
}
