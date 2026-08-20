import Foundation
import Observation

struct PromptCompletionMatch: Identifiable, Equatable {
    let id: String
    let kind: PromptCompletionKind
    let insertionValue: String
    let title: String
    let subtitle: String?
    let inputHint: String?
    let systemImage: String
    let appendsTrailingSpace: Bool
}

struct PromptCompletionCatalogKey: Equatable {
    private struct CommandKey: Equatable {
        let name: String
        let description: String?
        let hasInput: Bool?
        let inputHint: String?
    }

    private struct SkillKey: Equatable {
        let name: String
        let description: String?
        let shortDescription: String?
        let path: String?
        let scope: String?
        let enabled: Bool
    }

    private let commands: [CommandKey]
    private let skills: [SkillKey]

    init(commands: [SlashCommand], skills: [Skill]) {
        self.commands = commands.map {
            CommandKey(
                name: $0.name,
                description: $0.description,
                hasInput: $0.hasInput,
                inputHint: $0.inputHint
            )
        }
        self.skills = skills.map {
            SkillKey(
                name: $0.name,
                description: $0.description,
                shortDescription: $0.shortDescription,
                path: $0.path,
                scope: $0.scope,
                enabled: $0.enabled
            )
        }
    }
}

struct PromptCompletionCursorRequest: Equatable {
    let revision: Int
    let text: String
    let cursorOffset: Int
}

@Observable
final class PromptCompletionModel {
    enum Phase: Equatable {
        case idle
        case loading
        case indexing
        case results
        case failed
    }

    struct SearchKey: Equatable {
        let scope: WorkspaceFileSearchScope
        let query: String
        let retryCount: Int
        let presentationID: Int
    }

    static let resultLimit = 50
    static let maximumQueryByteCount = 256
    static let searchDebounce = Duration.milliseconds(150)

    private(set) var scope: WorkspaceFileSearchScope
    private(set) var kind: PromptCompletionKind?
    private(set) var query = ""
    private(set) var matches: [PromptCompletionMatch] = []
    private(set) var selectedMatchID: PromptCompletionMatch.ID?
    private(set) var phase = Phase.idle
    private(set) var retryCount = 0
    private(set) var cursorRequest: PromptCompletionCursorRequest?

    private let store: ThreadStore
    private var context: PromptCompletionInsertionContext?
    private var commands: [PromptCompletionMatch] = []
    private var skills: [PromptCompletionMatch] = []
    private var latestText = ""
    private var latestCursorOffset: Int?
    private var suppressedInput: SuppressedInput?
    private var presentationID = 0
    private var cursorRequestRevision = 0

    init(store: ThreadStore, scope: WorkspaceFileSearchScope) {
        self.store = store
        self.scope = scope
    }

    var isPresented: Bool {
        guard context != nil, let kind else { return false }
        return completionIsAvailable(for: kind)
    }

    var isFileCompletionAvailable: Bool {
        scope.isAvailable && store.connectionState == .connected
    }

    var searchKey: SearchKey? {
        guard kind == .workspaceFile, isPresented else { return nil }
        return SearchKey(
            scope: scope,
            query: query,
            retryCount: retryCount,
            presentationID: presentationID
        )
    }

    var selectedMatch: PromptCompletionMatch? {
        guard let selectedMatchID else { return matches.first }
        return matches.first { $0.id == selectedMatchID } ?? matches.first
    }

    func updateScope(_ scope: WorkspaceFileSearchScope) {
        guard self.scope != scope else { return }
        self.scope = scope
        dismiss()
    }

    func updateCatalog(commands: [SlashCommand], skills: [Skill]) {
        self.commands = commands.map(Self.commandMatch)
        self.skills = skills.filter(\.enabled).map(Self.skillMatch)
        reevaluateLatestInput()
    }

    func update(text: String, cursorOffset: Int?) {
        latestText = text
        latestCursorOffset = cursorOffset

        guard let cursorOffset else {
            clearPresentation()
            return
        }
        if suppressedInput == SuppressedInput(text: text, cursorOffset: cursorOffset) {
            clearPresentation()
            return
        }
        suppressedInput = nil

        if let context,
           let query = context.query(in: text, cursorOffset: cursorOffset),
           completionIsAvailable(for: context.kind) {
            setQuery(query, kind: context.kind)
            return
        }

        guard let context = PromptCompletionInsertionContext.detect(
            in: text,
            cursorOffset: cursorOffset
        ), completionIsAvailable(for: context.kind) else {
            clearPresentation()
            return
        }

        self.context = context
        kind = context.kind
        retryCount = 0
        presentationID += 1
        setQuery(
            context.query(in: text, cursorOffset: cursorOffset) ?? "",
            kind: context.kind,
            resetsResults: true
        )
    }

    func edit(selecting match: PromptCompletionMatch, in text: String) -> PromptCompletionEdit? {
        guard matches.contains(where: { $0.id == match.id }),
              let context,
              let edit = context.edit(
                replacingWith: match.insertionValue,
                appendsTrailingSpace: match.appendsTrailingSpace,
                in: text
              ) else { return nil }

        requestCursor(for: edit)
        latestText = edit.text
        latestCursorOffset = edit.cursorOffset
        suppressedInput = SuppressedInput(
            text: edit.text,
            cursorOffset: edit.cursorOffset
        )
        clearPresentation()
        return edit
    }

    func editBySelectingCurrentMatch(in text: String) -> PromptCompletionEdit? {
        guard let selectedMatch else { return nil }
        return edit(selecting: selectedMatch, in: text)
    }

    func textByPresentingFileCompletion(in text: String) -> String {
        let separator = text.isEmpty || text.last?.isWhitespace == true ? "" : " "
        let updatedText = "\(text)\(separator)@"
        let cursorOffset = updatedText.count

        suppressedInput = nil
        requestCursor(
            for: PromptCompletionEdit(
                text: updatedText,
                cursorOffset: cursorOffset
            )
        )
        update(text: updatedText, cursorOffset: cursorOffset)
        return updatedText
    }

    @discardableResult
    func dismiss() -> Bool {
        guard context != nil else { return false }
        if let latestCursorOffset {
            suppressedInput = SuppressedInput(
                text: latestText,
                cursorOffset: latestCursorOffset
            )
        }
        clearPresentation()
        return true
    }

    func retry() {
        guard kind == .workspaceFile else { return }
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

    func search() async {
        guard let requestedKey = searchKey else { return }
        guard requestedKey.scope.isAvailable,
              store.connectionState == .connected else {
            clearMatches(phase: .loading)
            return
        }

        clearMatches(phase: .loading)

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
                clearMatches(phase: .indexing)
                return
            }

            matches = result.entries.map { entry in
                Self.fileMatch(WorkspaceFileMatch(entry: entry))
            }
            selectedMatchID = matches.first?.id
            phase = .results
        } catch is CancellationError {
            return
        } catch {
            guard searchKey == requestedKey else { return }
            clearMatches(phase: .failed)
        }
    }

    private func reevaluateLatestInput() {
        guard latestCursorOffset != nil else {
            if let kind, !completionIsAvailable(for: kind) {
                clearPresentation()
            }
            return
        }
        update(text: latestText, cursorOffset: latestCursorOffset)
    }

    private func setQuery(
        _ query: String,
        kind: PromptCompletionKind,
        resetsResults: Bool = false
    ) {
        let query = Self.prefixFittingByteLimit(query)
        let changed = self.query != query || self.kind != kind
        self.query = query
        self.kind = kind

        switch kind {
        case .workspaceFile:
            if changed || resetsResults {
                clearMatches(phase: .loading)
            }
        case .slashCommand:
            applyStaticMatches(commands, query: query)
        case .skill:
            applyStaticMatches(skills, query: query)
        }
    }

    private func applyStaticMatches(
        _ candidates: [PromptCompletionMatch],
        query: String
    ) {
        let selectedMatchID = selectedMatchID
        matches = candidates.filter { candidate in
            query.isEmpty
                || candidate.insertionValue.localizedStandardContains(query)
                || candidate.title.localizedStandardContains(query)
                || candidate.subtitle?.localizedStandardContains(query) == true
                || candidate.inputHint?.localizedStandardContains(query) == true
        }
        self.selectedMatchID = matches.contains { $0.id == selectedMatchID }
            ? selectedMatchID
            : matches.first?.id
        phase = .results
    }

    private func completionIsAvailable(for kind: PromptCompletionKind) -> Bool {
        switch kind {
        case .workspaceFile:
            isFileCompletionAvailable
        case .slashCommand:
            !commands.isEmpty
        case .skill:
            !skills.isEmpty
        }
    }

    private func requestCursor(for edit: PromptCompletionEdit) {
        cursorRequestRevision += 1
        cursorRequest = PromptCompletionCursorRequest(
            revision: cursorRequestRevision,
            text: edit.text,
            cursorOffset: edit.cursorOffset
        )
    }

    private func clearPresentation() {
        context = nil
        kind = nil
        query = ""
        clearMatches(phase: .idle)
    }

    private func clearMatches(phase: Phase) {
        matches = []
        selectedMatchID = nil
        self.phase = phase
    }

    private static func fileMatch(_ match: WorkspaceFileMatch) -> PromptCompletionMatch {
        PromptCompletionMatch(
            id: "file:\(match.relativePath)",
            kind: .workspaceFile,
            insertionValue: match.relativePath,
            title: match.displayName,
            subtitle: match.directoryPath,
            inputHint: nil,
            systemImage: "doc.text",
            appendsTrailingSpace: true
        )
    }

    private static func commandMatch(_ command: SlashCommand) -> PromptCompletionMatch {
        let inputHint = command.inputHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PromptCompletionMatch(
            id: "command:\(command.name)",
            kind: .slashCommand,
            insertionValue: command.name,
            title: "/\(command.name)",
            subtitle: command.description,
            inputHint: inputHint?.isEmpty == false ? inputHint : nil,
            systemImage: "slash.circle",
            appendsTrailingSpace: command.hasInput == true || inputHint?.isEmpty == false
        )
    }

    private static func skillMatch(_ skill: Skill) -> PromptCompletionMatch {
        let description = skill.shortDescription?.isEmpty == false
            ? skill.shortDescription
            : skill.description
        return PromptCompletionMatch(
            id: "skill:\(skill.path ?? skill.name)",
            kind: .skill,
            insertionValue: skill.name,
            title: "$\(skill.name)",
            subtitle: description,
            inputHint: skill.scope,
            systemImage: "sparkles",
            appendsTrailingSpace: true
        )
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

    private struct SuppressedInput: Equatable {
        let text: String
        let cursorOffset: Int
    }
}
