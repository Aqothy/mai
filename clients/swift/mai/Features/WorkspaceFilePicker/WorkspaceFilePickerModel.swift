import Observation

@Observable
final class WorkspaceFilePickerModel {
    enum Phase: Equatable {
        case loading
        case indexing
        case results
        case failed
    }

    struct SearchKey: Equatable {
        let scope: WorkspaceFileSearchScope
        let query: String
        let retryCount: Int
    }

    static let resultLimit = 50
    static let maximumQueryByteCount = 256
    static let searchDebounce = Duration.milliseconds(150)

    private(set) var scope: WorkspaceFileSearchScope
    private(set) var query = "" {
        didSet {
            if query.utf8.count > Self.maximumQueryByteCount {
                query = Self.prefixFittingByteLimit(query)
            }
            if query != oldValue {
                clearResults(phase: .loading)
            }
        }
    }
    private(set) var matches: [WorkspaceFileMatch] = []
    private(set) var selectedMatchID: WorkspaceFileMatch.ID?
    private(set) var phase = Phase.loading
    private(set) var retryCount = 0

    private let store: ThreadStore
    private var insertionContext: WorkspaceFileInsertionContext?

    init(store: ThreadStore, scope: WorkspaceFileSearchScope) {
        self.store = store
        self.scope = scope
    }

    var searchKey: SearchKey {
        SearchKey(scope: scope, query: query, retryCount: retryCount)
    }

    var isAvailable: Bool {
        scope.isAvailable && store.connectionState == .connected
    }

    var isPresented: Bool {
        insertionContext != nil
    }

    private var selectedMatch: WorkspaceFileMatch? {
        guard let selectedMatchID else { return matches.first }
        return matches.first { $0.id == selectedMatchID } ?? matches.first
    }

    func updateScope(_ scope: WorkspaceFileSearchScope) {
        guard self.scope != scope else { return }
        self.scope = scope
        dismiss()
        prepareSearch()
    }

    func textDidChange(from oldText: String, to newText: String) {
        guard isAvailable else {
            dismiss()
            return
        }

        if let insertionContext {
            guard let query = insertionContext.query(in: newText) else {
                dismiss()
                return
            }
            self.query = query
            return
        }

        guard let insertionContext = WorkspaceFileInsertionContext.insertedAtSign(
            from: oldText,
            to: newText
        ), let query = insertionContext.query(in: newText) else { return }

        prepareSearch(query: query)
        self.insertionContext = insertionContext
    }

    func textBySelecting(relativePath: String, in text: String) -> String? {
        guard let insertionContext else { return nil }
        self.insertionContext = nil
        return insertionContext.inserting(relativePath: relativePath, into: text)
    }

    func textBySelectingCurrentMatch(in text: String) -> String? {
        guard let selectedMatch else { return nil }
        return textBySelecting(relativePath: selectedMatch.relativePath, in: text)
    }

    @discardableResult
    func dismiss() -> Bool {
        guard insertionContext != nil else { return false }
        insertionContext = nil
        return true
    }

    func retry() {
        retryCount += 1
    }

    func moveSelection(by offset: Int) -> Bool {
        guard isPresented, !matches.isEmpty, offset != 0 else { return false }
        let currentIndex = selectedMatchID.flatMap { id in
            matches.firstIndex { $0.id == id }
        } ?? (offset > 0 ? -1 : 0)
        let nextIndex = (currentIndex + offset + matches.count) % matches.count
        selectedMatchID = matches[nextIndex].id
        return true
    }

    private func prepareSearch(query: String = "") {
        let previousQuery = self.query
        self.query = query
        if self.query == previousQuery {
            clearResults(phase: .loading)
        }
        retryCount = 0
    }

    func search() async {
        let requestedKey = searchKey
        guard requestedKey.scope.isAvailable,
              store.connectionState == .connected else {
            clearResults(phase: .loading)
            return
        }

        clearResults(phase: .loading)

        do {
            if !requestedKey.query.isEmpty {
                try await Task.sleep(for: Self.searchDebounce)
            }

            let result = try await store.searchWorkspaceFiles(
                requestedKey.scope.request(
                    query: requestedKey.query,
                    limit: Self.resultLimit
                )
            )
            try Task.checkCancellation()
            guard searchKey == requestedKey else { return }

            if result.indexing == true {
                clearResults(phase: .indexing)
                return
            }

            matches = result.entries.map(WorkspaceFileMatch.init)
            selectedMatchID = matches.first?.id
            phase = .results
        } catch is CancellationError {
            return
        } catch {
            guard searchKey == requestedKey else { return }
            clearResults(phase: .failed)
        }
    }

    private func clearResults(phase: Phase) {
        matches = []
        selectedMatchID = nil
        self.phase = phase
    }

    private static func prefixFittingByteLimit(_ value: String) -> String {
        var end = value.startIndex
        var byteCount = 0

        while end < value.endIndex {
            let next = value.index(after: end)
            let characterByteCount = value[end..<next].utf8.count
            guard byteCount + characterByteCount <= maximumQueryByteCount else { break }
            byteCount += characterByteCount
            end = next
        }
        return String(value[..<end])
    }
}
