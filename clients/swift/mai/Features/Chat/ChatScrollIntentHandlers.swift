import Foundation

/// Where both platforms' scroll-intent controllers report what the reader
/// did with the transcript. Only the input each platform reads differs.
struct ChatScrollIntentHandlers {
    var isBottomFollowingEnabled: () -> Bool = { false }
    var noteUserScrollActivity: (_ isActive: Bool) -> Void = { _ in }
    var noteUserReachedEnd: () -> Void = {}
    /// A scroll without a drag or a gesture: a key, a status-bar tap,
    /// VoiceOver.
    var noteKeyboardScrollIntent: (_ towardEnd: Bool) -> Void = { _ in }

    /// A reader's scroll that started at `startY` ended at `endY`; one that
    /// ended at the transcript's end resumes following.
    func finishUserScroll(startY: CGFloat?, endY: CGFloat?, isNearBottom: Bool) {
        noteUserScrollActivity(false)
        if ChatScrollFollowPolicy.shouldRestoreFollowingAfterUserScroll(
            startY: startY, endY: endY, isNearBottom: isNearBottom)
        {
            noteUserReachedEnd()
        }
    }
}
