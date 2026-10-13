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
        let completes: Bool?
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
                inputHint: $0.inputHint,
                completes: $0.completes
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
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    enum Phase: Equatable {
        case idle
        case loading
        case indexing
        case results
        case failed
    }

    /// What to load: workspace files, or the suggestions for a command's
    /// input when `command` is set.
    struct SearchKey: Equatable {
        let scope: WorkspaceFileSearchScope
        let command: String?
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
    /// Workspace files picked from completions, by path relative to the
    /// search scope's directory.
    private(set) var mentionedFilePaths: Set<String> = []

    private let store: ThreadStore
    private var presentation: Presentation?
    private var commands: [PromptCompletionMatch] = []
    /// Commands whose provider suggests their input.
    private var completingCommands: Set<String> = []
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
        guard presentation != nil, let kind, completionIsAvailable(for: kind) else { return false }
        // Typed input with nothing to suggest, such as review instructions,
        // shows no panel.
        return kind != .commandInput || !matches.isEmpty
    }

    var isFileCompletionAvailable: Bool {
        scope.isAvailable && store.connectionState == .connected
    }

    var searchKey: SearchKey? {
        guard let presentation, let kind, completionIsAvailable(for: kind) else { return nil }
        let command: String?
        switch presentation {
        case .token where kind == .workspaceFile:
            command = nil
        case .commandInput(let context):
            command = context.command
        case .token:
            return nil
        }
        return SearchKey(
            scope: scope,
            command: command,
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
        completingCommands = Set(commands.filter { $0.completes == true }.map(\.name))
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
        if suppressedInput?.matches(text: text, cursorOffset: cursorOffset) == true {
            clearPresentation()
            return
        }
        suppressedInput = nil

        if case .token(let context) = presentation,
            let query = context.query(in: text, cursorOffset: cursorOffset),
            completionIsAvailable(for: context.kind)
        {
            setQuery(query, kind: context.kind)
            return
        }

        if let context = PromptCompletionInsertionContext.detect(
            in: text,
            cursorOffset: cursorOffset
        ), completionIsAvailable(for: context.kind) {
            present(
                .token(context),
                kind: context.kind,
                query: context.query(in: text, cursorOffset: cursorOffset) ?? ""
            )
            return
        }

        if let context = CommandInputContext.detect(
            in: text,
            cursorOffset: cursorOffset,
            commands: completingCommands
        ), completionIsAvailable(for: .commandInput) {
            let input = context.input(in: text)
            if presentation == .commandInput(context) {
                setQuery(input, kind: .commandInput)
            } else {
                present(.commandInput(context), kind: .commandInput, query: input)
            }
            return
        }

        clearPresentation()
    }

    func edit(selecting match: PromptCompletionMatch, in text: String) -> PromptCompletionEdit? {
        guard matches.contains(match), let presentation else { return nil }
        let context: PromptCompletionInsertionContext
        switch presentation {
        case .token(let tokenContext):
            context = tokenContext
        case .commandInput(let commandContext):
            return edit(selecting: match, after: commandContext)
        }
        guard
            let edit = context.edit(
                replacingWith: match.insertionValue,
                appendsTrailingSpace: match.appendsTrailingSpace,
                in: text
            )
        else { return nil }

        if match.kind == .workspaceFile {
            mentionedFilePaths.insert(match.insertionValue)
        }
        requestCursor(for: edit)
        if match.kind == .slashCommand, completingCommands.contains(match.insertionValue) {
            // A command with options shows them next, as the Codex app does.
            clearPresentation()
            update(text: edit.text, cursorOffset: edit.cursorOffset)
            return edit
        }
        latestText = edit.text
        latestCursorOffset = edit.cursorOffset
        // TextField can publish the inserted text before its new selection.
        // Keep an accepted token closed across those cursor updates.
        suppressedInput = .completed(text: edit.text)
        clearPresentation()
        return edit
    }

    /// Resource links for the picked files that `text` still mentions as an
    /// `@path` token, resolved against `directory`. Each provider decides how
    /// to pass them on; most already read the `@path` in the text.
    func fileMentionLinks(in text: String, directory: String) -> [Attachment] {
        let mentioned = Set(
            text.split(whereSeparator: \.isWhitespace)
                .filter { $0.hasPrefix("@") }
                .map { String($0.dropFirst()) }
        )
        return mentionedFilePaths.intersection(mentioned).sorted().map { path in
            let url = URL(filePath: directory).appending(path: path)
            return Attachment(
                data: nil, kind: MaidAttachmentKind.resourceLink.rawValue, mimeType: nil,
                name: url.lastPathComponent, uri: url.absoluteString
            )
        }
    }

    func clearMentionedFiles() {
        mentionedFilePaths.removeAll()
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
        guard presentation != nil else { return false }
        if let latestCursorOffset {
            suppressedInput = .dismissed(
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
        let currentIndex =
            selectedMatchID.flatMap { id in
                matches.firstIndex { $0.id == id }
            } ?? (offset > 0 ? -1 : 0)
        let nextIndex = (currentIndex + offset + matches.count) % matches.count
        selectedMatchID = matches[nextIndex].id
        return true
    }

    func search() async {
        guard let requestedKey = searchKey else { return }
        clearMatches(phase: .loading)

        do {
            if let command = requestedKey.command {
                try await loadCommandInput(command, for: requestedKey)
                return
            }
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

    /// Replaces a command's input with a suggestion. Input that ends in a
    /// space goes on, so what follows is offered next (a branch after
    /// `--base `); any other input is complete.
    private func edit(
        selecting match: PromptCompletionMatch,
        after context: CommandInputContext
    ) -> PromptCompletionEdit {
        let edit = context.edit(replacingWith: match.insertionValue)
        requestCursor(for: edit)
        if match.insertionValue.last?.isWhitespace == true {
            update(text: edit.text, cursorOffset: edit.cursorOffset)
        } else {
            latestText = edit.text
            latestCursorOffset = edit.cursorOffset
            suppressedInput = .completed(text: edit.text)
            clearPresentation()
        }
        return edit
    }

    private func loadCommandInput(_ command: String, for requestedKey: SearchKey) async throws {
        guard case .thread(let threadID) = requestedKey.scope else { return }
        let completions = try await store.completeCommand(
            CompleteCommandInput(command: command, input: requestedKey.query, threadID: threadID)
        )
        try Task.checkCancellation()
        guard searchKey == requestedKey else { return }
        matches = completions.map(Self.commandInputMatch)
        selectedMatchID = matches.first?.id
        phase = .results
    }

    private func present(
        _ presentation: Presentation,
        kind: PromptCompletionKind,
        query: String
    ) {
        self.presentation = presentation
        self.kind = kind
        retryCount = 0
        presentationID += 1
        setQuery(query, kind: kind, resetsResults: true)
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
        case .workspaceFile, .commandInput:
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
        self.selectedMatchID =
            matches.contains { $0.id == selectedMatchID }
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
        case .commandInput:
            // Suggestions come from the thread's provider.
            if case .thread = scope { isFileCompletionAvailable } else { false }
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
        presentation = nil
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

    private static func commandInputMatch(_ completion: CommandCompletion) -> PromptCompletionMatch {
        PromptCompletionMatch(
            id: "input:\(completion.input)",
            kind: .commandInput,
            insertionValue: completion.input,
            title: completion.label,
            subtitle: completion.description,
            inputHint: nil,
            systemImage: "arrow.turn.down.right",
            appendsTrailingSpace: false
        )
    }

    private static func skillMatch(_ skill: Skill) -> PromptCompletionMatch {
        let description =
            skill.shortDescription?.isEmpty == false
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

    /// What the panel completes: a token (`@file`, `/command`, `$skill`) or
    /// the input after a command its provider completes.
    private enum Presentation: Equatable {
        case token(PromptCompletionInsertionContext)
        case commandInput(CommandInputContext)
    }

    /// The input after a leading `/command ` whose provider suggests it.
    private struct CommandInputContext: Equatable {
        let command: String
        /// The `/command ` text before the input.
        let prefix: String

        static func detect(
            in text: String,
            cursorOffset: Int,
            commands: Set<String>
        ) -> CommandInputContext? {
            guard text.first == "/", let end = text.firstIndex(where: \.isWhitespace) else {
                return nil
            }
            let command = String(text[text.index(after: text.startIndex)..<end])
            let prefix = String(text[...end])
            guard commands.contains(command), cursorOffset >= prefix.count else { return nil }
            return CommandInputContext(command: command, prefix: prefix)
        }

        func input(in text: String) -> String {
            String(text.dropFirst(prefix.count))
        }

        func edit(replacingWith input: String) -> PromptCompletionEdit {
            let text = prefix + input
            return PromptCompletionEdit(text: text, cursorOffset: text.count)
        }
    }

    private enum SuppressedInput {
        case completed(text: String)
        case dismissed(text: String, cursorOffset: Int)

        func matches(text: String, cursorOffset: Int) -> Bool {
            switch self {
            case .completed(let completedText):
                completedText == text
            case .dismissed(let dismissedText, let dismissedOffset):
                dismissedText == text && dismissedOffset == cursorOffset
            }
        }
    }
}
