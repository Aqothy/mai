import Foundation

/// Which history a request to load earlier turns was made for: the oldest
/// section shown and the oldest the store holds.
struct ChatTimelineHistoryPosition: Equatable {
    let oldestLoadedSectionID: String?
    let oldestSectionID: String?
}
