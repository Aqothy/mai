enum PromptCompletionKind: String, CaseIterable, Hashable {
    case workspaceFile
    case slashCommand
    case skill

    var trigger: Character {
        switch self {
        case .workspaceFile: "@"
        case .slashCommand: "/"
        case .skill: "$"
        }
    }

    static func kind(for trigger: Character) -> PromptCompletionKind? {
        allCases.first { $0.trigger == trigger }
    }
}

struct PromptCompletionEdit: Equatable {
    let text: String
    let cursorOffset: Int
}

/// A character-indexed replacement context for a completion trigger.
///
/// Prefix and suffix snapshots make replacements resilient to Unicode and to
/// triggers inserted in the middle of a prompt. Text entered after the trigger
/// grows the replaceable range while text that was already after the caret is
/// preserved.
struct PromptCompletionInsertionContext: Equatable {
    let kind: PromptCompletionKind

    private let prefix: String
    private let suffix: String

    static func detect(
        in text: String,
        cursorOffset: Int
    ) -> PromptCompletionInsertionContext? {
        guard cursorOffset > 0, cursorOffset <= text.count else { return nil }

        let cursorIndex = text.index(text.startIndex, offsetBy: cursorOffset)
        var triggerIndex = cursorIndex

        while triggerIndex > text.startIndex {
            let previousIndex = text.index(before: triggerIndex)
            if text[previousIndex].isWhitespace {
                break
            }
            triggerIndex = previousIndex
        }

        guard triggerIndex < cursorIndex,
            let kind = PromptCompletionKind.kind(for: text[triggerIndex])
        else {
            return nil
        }

        return PromptCompletionInsertionContext(
            kind: kind,
            prefix: String(text[..<triggerIndex]),
            suffix: String(text[cursorIndex...])
        )
    }

    func query(in text: String, cursorOffset: Int) -> String? {
        guard let bounds = completionBounds(in: text),
            cursorOffset >= bounds.queryStartOffset,
            cursorOffset <= bounds.queryEndOffset
        else { return nil }

        let cursorIndex = text.index(text.startIndex, offsetBy: cursorOffset)
        return String(text[bounds.queryStart..<cursorIndex])
    }

    func edit(
        replacingWith value: String,
        appendsTrailingSpace: Bool,
        in text: String
    ) -> PromptCompletionEdit? {
        guard let bounds = completionBounds(in: text) else { return nil }

        let needsSeparator =
            suffix.first.map { !$0.isWhitespace }
            ?? appendsTrailingSpace
        let separator = needsSeparator ? " " : ""
        let replacement = "\(kind.trigger)\(value)\(separator)"

        var updatedText = text
        updatedText.replaceSubrange(
            bounds.trigger..<bounds.queryEnd,
            with: replacement
        )
        return PromptCompletionEdit(
            text: updatedText,
            cursorOffset: prefix.count + replacement.count
        )
    }

    private func completionBounds(in text: String) -> CompletionBounds? {
        guard text.hasPrefix(prefix), text.hasSuffix(suffix) else { return nil }

        let trigger = text.index(text.startIndex, offsetBy: prefix.count)
        guard trigger < text.endIndex, text[trigger] == kind.trigger else {
            return nil
        }

        let queryStart = text.index(after: trigger)
        let queryEnd = text.index(text.endIndex, offsetBy: -suffix.count)
        guard queryStart <= queryEnd,
            !text[queryStart..<queryEnd].contains(where: \.isWhitespace)
        else {
            return nil
        }

        return CompletionBounds(
            trigger: trigger,
            queryStart: queryStart,
            queryEnd: queryEnd,
            queryStartOffset: prefix.count + 1,
            queryEndOffset: text.count - suffix.count
        )
    }

    private struct CompletionBounds {
        let trigger: String.Index
        let queryStart: String.Index
        let queryEnd: String.Index
        let queryStartOffset: Int
        let queryEndOffset: Int
    }
}
