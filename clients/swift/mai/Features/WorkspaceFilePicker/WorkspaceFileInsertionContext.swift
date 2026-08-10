struct WorkspaceFileInsertionContext: Equatable {
    private let prefix: String
    private let suffix: String

    static func insertedAtSign(
        from oldText: String,
        to newText: String
    ) -> WorkspaceFileInsertionContext? {
        let difference = newText.difference(from: oldText)
        guard difference.count == 1,
              let change = difference.first,
              case .insert(let offset, let character, _) = change,
              character == "@" else { return nil }

        if offset > 0 {
            let insertionIndex = newText.index(newText.startIndex, offsetBy: offset)
            let previousIndex = newText.index(before: insertionIndex)
            guard newText[previousIndex].isWhitespace else { return nil }
        }

        let insertionIndex = newText.index(newText.startIndex, offsetBy: offset)
        let suffixStart = newText.index(after: insertionIndex)
        return WorkspaceFileInsertionContext(
            prefix: String(newText[..<insertionIndex]),
            suffix: String(newText[suffixStart...])
        )
    }

    func query(in text: String) -> String? {
        guard let range = mentionRange(in: text) else { return nil }
        let queryStart = text.index(after: range.lowerBound)
        return String(text[queryStart..<range.upperBound])
    }

    func inserting(relativePath: String, into currentText: String) -> String {
        guard let range = mentionRange(in: currentText) else {
            return Self.appending(relativePath: relativePath, to: currentText)
        }

        var updatedText = currentText
        let trailingSpace = suffix.first?.isWhitespace == true ? "" : " "
        updatedText.replaceSubrange(range, with: "@\(relativePath)\(trailingSpace)")
        return updatedText
    }

    private func mentionRange(in text: String) -> Range<String.Index>? {
        guard text.hasPrefix(prefix), text.hasSuffix(suffix) else { return nil }

        let triggerIndex = text.index(text.startIndex, offsetBy: prefix.count)
        guard triggerIndex < text.endIndex, text[triggerIndex] == "@" else { return nil }

        let queryStart = text.index(after: triggerIndex)
        let queryEnd = text.index(text.endIndex, offsetBy: -suffix.count)
        guard queryStart <= queryEnd,
              !text[queryStart..<queryEnd].contains(where: \.isWhitespace) else { return nil }
        return triggerIndex..<queryEnd
    }

    private static func appending(relativePath: String, to text: String) -> String {
        let separator = text.isEmpty || text.last?.isWhitespace == true ? "" : " "
        return "\(text)\(separator)@\(relativePath) "
    }
}
