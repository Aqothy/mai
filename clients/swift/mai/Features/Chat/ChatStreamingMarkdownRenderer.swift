import Foundation

nonisolated struct ChatStreamingMarkdownRepair: Equatable, Sendable {
    enum Kind: String, CaseIterable, Hashable, Sendable {
        case codeFence
        case inlineCode
        case link
        case table
        case blockMarker
        case emphasis
        case strikethrough
    }

    let displaySource: String
    let appliedKinds: Set<Kind>
    let openCodeBlock: ChatMarkdownCodeBlock?

    static func diagnosticSummary(for appliedKinds: Set<Kind>) -> String {
        Kind.allCases
            .filter(appliedKinds.contains)
            .map(\.rawValue)
            .joined(separator: ", ")
    }
}

/// Makes only the unstable tail parseable. The provider's exact source is
/// never mutated and receives a normal full parse when streaming finishes.
/// These repairs intentionally cover common model output, not all CommonMark.
nonisolated enum ChatStreamingMarkdownRepairer {
    private struct Fence {
        let marker: Character
        let length: Int
        let contentStart: String.Index
        let language: String?
        let isFirstBlock: Bool
    }

    static func repair(_ source: String) -> ChatStreamingMarkdownRepair {
        guard !source.isEmpty else {
            return ChatStreamingMarkdownRepair(
                displaySource: source,
                appliedKinds: [],
                openCodeBlock: nil
            )
        }

        var display = source
        var kinds: Set<ChatStreamingMarkdownRepair.Kind> = []

        // An open fence owns the entire tail, so inline punctuation inside it
        // must remain literal. swift-markdown already treats EOF as its close;
        // a standalone fence can bypass parsing with this lightweight model.
        if let fence = openFence(in: display) {
            let code = String(display[fence.contentStart...])
            let openCodeBlock = fence.isFirstBlock
                ? ChatMarkdownCodeBlock(
                    code: code.hasSuffix("\n")
                        ? String(code.dropLast()) : code,
                    language: fence.language,
                    kind: .fenced
                )
                : nil
            return ChatStreamingMarkdownRepair(
                displaySource: display,
                appliedKinds: [.codeFence],
                openCodeBlock: openCodeBlock
            )
        }

        if repairPartialTableDelimiter(in: &display) {
            kinds.insert(.table)
        }
        if simplifyIncompleteLink(in: &display)
            || simplifyIncompleteAutolink(in: &display)
        {
            kinds.insert(.link)
        }
        if repairOpenInlineCode(in: &display) {
            kinds.insert(.inlineCode)
        }
        if suppressTrailingBlockMarker(in: &display) {
            kinds.insert(.blockMarker)
        }
        if repairDelimiter("~~", in: &display) {
            kinds.insert(.strikethrough)
        }
        for delimiter in ["**", "__", "*", "_"] {
            if repairDelimiter(delimiter, in: &display) {
                kinds.insert(.emphasis)
            }
        }

        return ChatStreamingMarkdownRepair(
            displaySource: display,
            appliedKinds: kinds,
            openCodeBlock: nil
        )
    }

    private static func openFence(in source: String) -> Fence? {
        var open: Fence?

        for lineSlice in source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let characters = Array(lineSlice)
            var cursor = 0
            while cursor < characters.count,
                characters[cursor] == " ",
                cursor < 3
            {
                cursor += 1
            }
            guard cursor < characters.count,
                characters[cursor] == "`" || characters[cursor] == "~"
            else { continue }

            let marker = characters[cursor]
            let markerStart = cursor
            while cursor < characters.count, characters[cursor] == marker {
                cursor += 1
            }
            let length = cursor - markerStart
            guard length >= 3 else { continue }

            if let current = open {
                if marker == current.marker,
                    length >= current.length,
                    characters[cursor...].allSatisfy({ $0.isWhitespace })
                {
                    open = nil
                }
            } else if marker != "`" || !characters[cursor...].contains("`") {
                let language = String(characters[cursor...])
                    .trimmingCharacters(in: .whitespaces)
                open = Fence(
                    marker: marker,
                    length: length,
                    contentStart: lineSlice.endIndex < source.endIndex
                        ? source.index(after: lineSlice.endIndex)
                        : source.endIndex,
                    language: language.isEmpty ? nil : language,
                    isFirstBlock: source[..<lineSlice.startIndex]
                        .allSatisfy(\.isWhitespace)
                )
            }
        }
        return open
    }

    /// A header plus a partly typed delimiter row is enough evidence to show
    /// a table. Missing delimiter cells are synthesized only in the display
    /// copy, then disappear when the real row becomes valid.
    private static func repairPartialTableDelimiter(
        in source: inout String
    ) -> Bool {
        let lineStart = source.lastIndex(of: "\n").map {
            source.index(after: $0)
        } ?? source.startIndex
        guard lineStart > source.startIndex else { return false }

        let previousLineEnd = source.index(before: lineStart)
        let previousLineStart = source[..<previousLineEnd]
            .lastIndex(of: "\n")
            .map { source.index(after: $0) } ?? source.startIndex
        let header = String(source[previousLineStart..<previousLineEnd])
        let delimiter = String(source[lineStart...])
        let trimmedDelimiter = delimiter.trimmingCharacters(
            in: .whitespaces
        )

        let headerCells = tableCells(in: header)
        let delimiterCells = tableCells(in: trimmedDelimiter)
        guard headerCells.count >= 2,
            trimmedDelimiter.contains("|"),
            trimmedDelimiter.contains("-"),
            trimmedDelimiter.allSatisfy({
                $0 == "|" || $0 == ":" || $0 == "-" || $0.isWhitespace
            })
        else { return false }

        let isComplete = delimiterCells.count == headerCells.count
            && delimiterCells.allSatisfy {
                $0.filter { $0 == "-" }.count >= 3
            }
        guard !isComplete else { return false }

        let repairedCells = (0..<headerCells.count).map { column in
            let partial = delimiterCells.indices.contains(column)
                ? delimiterCells[column].trimmingCharacters(in: .whitespaces)
                : ""
            let leadingColon = partial.hasPrefix(":")
            let trailingColon = partial.hasSuffix(":")
            return (leadingColon ? ":" : "")
                + "---"
                + (trailingColon ? ":" : "")
        }
        source.replaceSubrange(
            lineStart...,
            with: "| " + repairedCells.joined(separator: " | ") + " |"
        )
        return true
    }

    private static func tableCells(in line: String) -> [String] {
        var cells = line.split(
            separator: "|",
            omittingEmptySubsequences: false
        ).map(String.init)
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            cells.removeFirst()
        }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            cells.removeLast()
        }
        return cells
    }

    private static func simplifyIncompleteLink(
        in source: inout String
    ) -> Bool {
        let paragraph = trailingParagraphRange(in: source)
        var searchEnd = source.endIndex

        while searchEnd > paragraph.lowerBound,
            let start = source.range(
                of: "[",
                options: .backwards,
                range: paragraph.lowerBound..<searchEnd
            )?.lowerBound
        {
            searchEnd = start
            let previous = start > source.startIndex
                ? source[source.index(before: start)] : nil
            guard previous != "!",
                !isEscaped(start, in: source),
                !isInsideInlineCode(start, in: source)
            else { continue }

            let labelStart = source.index(after: start)
            guard let labelEnd = source[labelStart...].firstIndex(of: "]") else {
                source.remove(at: start)
                return true
            }
            let destinationStart = source.index(after: labelEnd)
            guard destinationStart < source.endIndex,
                source[destinationStart] == "(",
                matchingParenthesis(
                    in: source,
                    openingAt: destinationStart
                ) == nil
            else { continue }

            let label = source[labelStart..<labelEnd]
            source.replaceSubrange(start..., with: label)
            return true
        }
        return false
    }

    private static func simplifyIncompleteAutolink(
        in source: inout String
    ) -> Bool {
        let paragraph = trailingParagraphRange(in: source)
        guard let start = source.range(
            of: "<",
            options: .backwards,
            range: paragraph
        )?.lowerBound,
            !source[source.index(after: start)...].contains(">")
        else { return false }

        let destination = source[source.index(after: start)...].lowercased()
        guard destination.hasPrefix("https://")
            || destination.hasPrefix("http://")
            || destination.hasPrefix("mailto:")
        else { return false }
        source.remove(at: start)
        return true
    }

    private static func repairOpenInlineCode(
        in source: inout String
    ) -> Bool {
        let paragraph = trailingParagraphRange(in: source)
        var openRuns: [Int: String.Index] = [:]
        var cursor = paragraph.lowerBound

        while cursor < source.endIndex {
            guard source[cursor] == "`", !isEscaped(cursor, in: source) else {
                cursor = source.index(after: cursor)
                continue
            }
            let start = cursor
            var length = 0
            while cursor < source.endIndex, source[cursor] == "`" {
                length += 1
                cursor = source.index(after: cursor)
            }
            if openRuns[length] == nil {
                openRuns[length] = start
            } else {
                openRuns[length] = nil
            }
        }

        guard let (length, start) = openRuns.max(by: {
            $0.value < $1.value
        }) else { return false }
        let contentStart = source.index(start, offsetBy: length)
        let content = source[contentStart...]
        if content.contains(where: { !$0.isWhitespace }) {
            source += String(repeating: "`", count: length)
        } else {
            source.removeSubrange(start..<contentStart)
        }
        return true
    }

    private static func suppressTrailingBlockMarker(
        in source: inout String
    ) -> Bool {
        let lineStart = source.lastIndex(of: "\n").map {
            source.index(after: $0)
        } ?? source.startIndex
        let marker = source[lineStart...]
            .trimmingCharacters(in: .whitespaces)
        guard !marker.isEmpty else { return false }

        let isHeading = (1...6).contains(marker.count)
            && marker.allSatisfy { $0 == "#" }
        let isQuote = marker.allSatisfy { $0 == ">" }
        let isList = ["-", "+", "*"].contains(marker)
        let isTable = marker == "|"
        let isOrderedList = marker.last.map { $0 == "." || $0 == ")" }
            == true && marker.dropLast().allSatisfy(\.isNumber)
        guard isHeading || isQuote || isList || isTable || isOrderedList
        else { return false }
        source.removeSubrange(lineStart...)
        return true
    }

    private static func repairDelimiter(
        _ delimiter: String,
        in source: inout String
    ) -> Bool {
        let ranges = delimiterRanges(delimiter, in: source)
        guard ranges.count % 2 == 1, let last = ranges.last else {
            return false
        }
        let suffix = source[last.upperBound...]
        if suffix.isEmpty {
            source.removeSubrange(last)
        } else if !suffix.first!.isWhitespace,
            !suffix.contains("\n"),
            !hasOpenInlineCode(String(suffix))
        {
            source += delimiter
        } else {
            return false
        }
        return true
    }

    private static func delimiterRanges(
        _ delimiter: String,
        in source: String
    ) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var cursor = source.startIndex

        while cursor < source.endIndex,
            let range = source.range(
                of: delimiter,
                range: cursor..<source.endIndex
            )
        {
            cursor = range.upperBound
            guard !isEscaped(range.lowerBound, in: source),
                !isInsideInlineCode(range.lowerBound, in: source)
            else { continue }
            if delimiter.count == 1 {
                let previous = range.lowerBound > source.startIndex
                    ? source[source.index(before: range.lowerBound)] : nil
                let next = range.upperBound < source.endIndex
                    ? source[range.upperBound] : nil
                if String(previous.map(String.init) ?? "") == delimiter
                    || String(next.map(String.init) ?? "") == delimiter
                {
                    continue
                }
            }
            result.append(range)
        }
        return result
    }

    private static func hasOpenInlineCode(_ source: String) -> Bool {
        delimiterRanges("`", in: source).count % 2 == 1
    }

    private static func trailingParagraphRange(
        in source: String
    ) -> Range<String.Index> {
        let start = source.range(of: "\n\n", options: .backwards)
            .map(\.upperBound) ?? source.startIndex
        return start..<source.endIndex
    }

    private static func matchingParenthesis(
        in source: String,
        openingAt start: String.Index
    ) -> String.Index? {
        var depth = 0
        var cursor = start
        while cursor < source.endIndex {
            if !isEscaped(cursor, in: source) {
                if source[cursor] == "(" { depth += 1 }
                if source[cursor] == ")" {
                    depth -= 1
                    if depth == 0 { return cursor }
                }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func isInsideInlineCode(
        _ index: String.Index,
        in source: String
    ) -> Bool {
        var count = 0
        var cursor = trailingParagraphRange(in: source).lowerBound
        while cursor < index {
            if source[cursor] == "`", !isEscaped(cursor, in: source) {
                count += 1
            }
            cursor = source.index(after: cursor)
        }
        return count % 2 == 1
    }

    private static func isEscaped(
        _ index: String.Index,
        in source: String
    ) -> Bool {
        var cursor = index
        var slashCount = 0
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            guard source[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }
        return slashCount % 2 == 1
    }
}

nonisolated struct ChatStreamingMarkdownSnapshot: Equatable, Sendable {
    let plan: ChatMarkdownRenderPlan
    let appliedRepairKinds: Set<ChatStreamingMarkdownRepair.Kind>
    let stableBlockCount: Int
}

/// Keeps completed root blocks and reparses only the last unstable block.
/// This keeps the useful stable-prefix idea from the earlier experiment and
/// adds a repaired display tail before parsing.
nonisolated struct ChatIncrementalMarkdownRenderPlanner {
    private var stableUTF8Count = 0
    private var stableBlocks: [ChatMarkdownRenderPlan.Block] = []
    private var previousSource = ""
    private var requiresFullDocumentParse = false

    mutating func snapshot(
        source: String,
        sourceIsAppendOnly: Bool = false
    ) -> ChatStreamingMarkdownSnapshot {
        if stableUTF8Count > source.utf8.count
            || (!sourceIsAppendOnly && !source.hasPrefix(previousSource))
        {
            reset()
        }

        let sourceUTF8 = source.utf8
        let tailStart = sourceUTF8.index(
            sourceUTF8.startIndex,
            offsetBy: stableUTF8Count
        )
        var rawTail = String(
            decoding: sourceUTF8[tailStart...],
            as: UTF8.self
        )

        // A reference definition can affect links before the active tail.
        // Detect it before that tail becomes stable, then keep full-document
        // parsing enabled for the remainder of this message.
        if !requiresFullDocumentParse,
            containsReferenceDefinition(rawTail)
        {
            requiresFullDocumentParse = true
            stableUTF8Count = 0
            stableBlocks.removeAll(keepingCapacity: true)
            rawTail = source
        }

        let repair = ChatStreamingMarkdownRepairer.repair(rawTail)
        let parsed = repair.openCodeBlock.map {
            [
                ChatMarkdownRenderPlanner.ParsedBlock(
                    utf8Offset: 0,
                    block: .code($0)
                )
            ]
        } ?? ChatMarkdownRenderPlanner.parsedBlocks(
            from: repair.displaySource
        )

        let activeBlocks: [ChatMarkdownRenderPlan.Block]
        if !requiresFullDocumentParse,
            parsed.count > 1,
            let active = parsed.last,
            active.utf8Offset > 0
        {
            stableBlocks = ChatMarkdownRenderPlan(
                blocks: stableBlocks + parsed.dropLast().map(\.block)
            ).blocks
            stableUTF8Count += active.utf8Offset
            activeBlocks = [active.block]
        } else if parsed.isEmpty {
            activeBlocks = []
        } else {
            activeBlocks = parsed.map(\.block)
        }

        previousSource = sourceIsAppendOnly ? "" : source
        let plan = ChatMarkdownRenderPlan(
            streamingStableBlocks: stableBlocks,
            activeBlocks: activeBlocks
        )
        return ChatStreamingMarkdownSnapshot(
            plan: plan,
            appliedRepairKinds: repair.appliedKinds,
            stableBlockCount: stableBlocks.count
        )
    }

    mutating func reset() {
        stableUTF8Count = 0
        stableBlocks.removeAll(keepingCapacity: true)
        previousSource = ""
        requiresFullDocumentParse = false
    }

    private func containsReferenceDefinition(_ source: String) -> Bool {
        source.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[") && trimmed.contains("]:")
        }
    }
}

/// One serial worker per visible live message. Cancellation makes requests
/// latest-wins without spawning overlapping full-document parses.
actor ChatStreamingMarkdownRenderWorker {
    private var planner = ChatIncrementalMarkdownRenderPlanner()

    func render(
        source: String,
        sourceIsAppendOnly: Bool
    ) -> ChatStreamingMarkdownSnapshot? {
        guard !Task.isCancelled else { return nil }
        let snapshot = planner.snapshot(
            source: source,
            sourceIsAppendOnly: sourceIsAppendOnly
        )
        guard !Task.isCancelled else { return nil }
        return snapshot
    }
}
