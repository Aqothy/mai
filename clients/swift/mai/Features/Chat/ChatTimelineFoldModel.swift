import Observation
import SwiftUI

/// Expanded/collapsed turn sections. A reference type so rows can toggle the
/// fold without closure or binding inputs defeating row-level invalidation.
@Observable
final class ChatTimelineFoldModel {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    private(set) var expandedSectionIDs: Set<String> = []
    /// The reader's explicit choices for disclosures inside sections, keyed by
    /// stable item identity. Rows are recreated when they leave the viewport,
    /// so a choice must outlive them for the rest of this chat's timeline.
    private(set) var disclosureChoices: [ChatDisclosure: Bool] = [:]

    func toggle(_ sectionID: String) {
        withChatContentExpansionTransaction {
            expandedSectionIDs.formSymmetricDifference([sectionID])
        }
    }

    func isExpanded(_ disclosure: ChatDisclosure, default defaultValue: Bool = false) -> Bool {
        disclosureChoices[disclosure] ?? defaultValue
    }

    func setExpanded(_ disclosure: ChatDisclosure, _ isExpanded: Bool) {
        withChatContentExpansionTransaction {
            disclosureChoices[disclosure] = isExpanded
        }
    }
}

nonisolated enum ChatDisclosure: Hashable {
    case thought(itemID: String)
    case activityGroup(id: String)
    case activityItem(itemID: String)
}

/// A disclosure should grow in place without an animated layout transition.
private func withChatContentExpansionTransaction(
    _ changes: () -> Void
) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, changes)
}
