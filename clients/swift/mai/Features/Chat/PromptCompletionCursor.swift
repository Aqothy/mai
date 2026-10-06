import SwiftUI

enum PromptCompletionCursor {
    static func offset(for selection: TextSelection?, in text: String) -> Int? {
        guard let selection else { return text.count }
        switch selection.indices {
        case .selection(let range):
            guard range.isEmpty else { return nil }

            // SwiftUI can publish the new selection before the bound draft
            // changes. Only match boundaries from the current string: walking
            // it with the other revision's index can trap, even during a paste.
            if range.lowerBound == text.endIndex { return text.count }
            return text.indices.enumerated().first {
                $0.element == range.lowerBound
            }?.offset
        case .multiSelection(_):
            return nil
        @unknown default:
            return nil
        }
    }
}
