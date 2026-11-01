import Foundation

/// Immutable, Sendable output from Markdown parsing. Views receive these
/// small value models instead of retaining swift-markdown's reference tree.
nonisolated struct ChatMarkdownRenderPlan: Equatable, Sendable {
    enum Block: Equatable, Sendable {
        case prose(ChatMarkdownProseRun)
        case code(ChatMarkdownCodeBlock)
        case table(ChatMarkdownTable)
    }

    let blocks: [Block]

    init(blocks: [Block]) {
        self.blocks = Self.coalescingProse(in: blocks)
    }

    /// Completed prose is one selectable TextKit run. The active trailing
    /// block stays separate so token updates never relayout that text view.
    init(
        streamingStableBlocks: [Block],
        activeBlocks: [Block]
    ) {
        self.blocks = streamingStableBlocks + activeBlocks
    }

    private static func coalescingProse(
        in blocks: [Block]
    ) -> [Block] {
        var result: [Block] = []
        result.reserveCapacity(blocks.count)
        var run: [ChatMarkdownProseRun] = []

        func appendRun() {
            guard !run.isEmpty else { return }
            result.append(.prose(ChatMarkdownProseRun(joining: run)))
            run.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            if case .prose(let prose) = block {
                run.append(prose)
            } else {
                appendRun()
                result.append(block)
            }
        }
        appendRun()
        return result
    }
}

/// Consecutive prose root blocks: their source and their text rendered from
/// the whole parsed document, so reference links stay resolved.
nonisolated struct ChatMarkdownProseRun: Equatable, Sendable {
    let source: String
    let text: ChatMarkdownText

    init(source: String, text: ChatMarkdownText) {
        self.source = source
        self.text = text
    }

    init(joining runs: [ChatMarkdownProseRun]) {
        if runs.count == 1, let run = runs.first {
            self = run
        } else {
            self.init(
                source: runs.map(\.source).joined(),
                text: ChatMarkdownText(
                    ChatMarkdownTextRenderer.joined(runs.map(\.text.value))
                )
            )
        }
    }
}

nonisolated struct ChatMarkdownCodeBlock: Equatable, Sendable {
    let code: String
    let language: String?

    var displayLanguage: String {
        guard let language = language?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !language.isEmpty else {
            return "Code"
        }

        switch language.lowercased() {
        case "bash", "sh", "shell":
            return "Bash"
        case "csharp", "cs":
            return "C#"
        case "cpp", "c++":
            return "C++"
        case "css":
            return "CSS"
        case "go", "golang":
            return "Go"
        case "html":
            return "HTML"
        case "javascript", "js", "jsx":
            return "JavaScript"
        case "json":
            return "JSON"
        case "kotlin":
            return "Kotlin"
        case "markdown", "md":
            return "Markdown"
        case "objective-c", "objc":
            return "Objective-C"
        case "python", "py":
            return "Python"
        case "ruby", "rb":
            return "Ruby"
        case "rust":
            return "Rust"
        case "sql":
            return "SQL"
        case "swift":
            return "Swift"
        case "typescript", "ts", "tsx":
            return "TypeScript"
        case "xml":
            return "XML"
        case "yaml", "yml":
            return "YAML"
        default:
            return language.capitalized
        }
    }
}

nonisolated struct ChatMarkdownTable: Equatable, Sendable {
    enum ColumnAlignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    let alignments: [ColumnAlignment]
    let header: [ChatMarkdownText]
    let rows: [[ChatMarkdownText]]

    var columnCount: Int {
        max(
            header.count,
            rows.lazy.map(\.count).max() ?? 0
        )
    }

    /// A whole-table representation that pastes cleanly into plain-text
    /// editors and spreadsheet apps.
    var tabSeparatedText: String {
        ([header] + rows)
            .map { row in
                (0..<columnCount)
                    .map { column in
                        guard row.indices.contains(column) else { return "" }
                        return row[column].string
                    }
                    .joined(separator: "\t")
            }
            .joined(separator: "\n")
    }
}

nonisolated struct ChatMarkdownRenderRequest: Hashable, Sendable {
    let messageID: String
    let source: String
}
