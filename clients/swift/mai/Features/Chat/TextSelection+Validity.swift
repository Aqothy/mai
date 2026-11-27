import SwiftUI

extension TextSelection {
    /// Whether every selected index is a scalar boundary within `text`.
    ///
    /// A selection made in other text, such as the draft an accepted send just
    /// cleared, is invalid here; iOS 18's text field traps when it applies one.
    func isValid(in text: String) -> Bool {
        let ranges: [Range<String.Index>]
        switch indices {
        case .selection(let range):
            ranges = [range]
        case .multiSelection(let rangeSet):
            ranges = Array(rangeSet.ranges)
        @unknown default:
            return false
        }
        return ranges.allSatisfy { range in
            [range.lowerBound, range.upperBound].allSatisfy { index in
                index <= text.endIndex
                    && index.samePosition(in: text.unicodeScalars) != nil
            }
        }
    }
}
