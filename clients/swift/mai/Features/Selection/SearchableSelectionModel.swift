import Foundation
import Observation

@Observable
final class SearchableSelectionModel {
    let choices: [SearchableSelectionChoice]
    var searchText = ""

    init(choices: [SearchableSelectionChoice]) {
        self.choices = choices
    }

    var visibleChoices: [SearchableSelectionChoice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return choices }
        return choices.filter { choice in
            choice.title.localizedStandardContains(query)
                || choice.subtitle?.localizedStandardContains(query) == true
        }
    }
}
