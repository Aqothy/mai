import Foundation

/// Immutable, Sendable output from Markdown parsing. SwiftUI receives these
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
        var proseSources: [String] = []
        var prosePieces: [ChatMarkdownProseRun.Piece] = []

        for block in blocks {
            if case .prose(let prose) = block {
                proseSources.append(prose.source)
                prosePieces.append(contentsOf: prose.pieces)
            } else {
                appendProseRun(
                    sources: &proseSources,
                    pieces: &prosePieces,
                    to: &result
                )
                result.append(block)
            }
        }
        appendProseRun(
            sources: &proseSources,
            pieces: &prosePieces,
            to: &result
        )
        return result
    }

    private static func appendProseRun(
        sources: inout [String],
        pieces: inout [ChatMarkdownProseRun.Piece],
        to blocks: inout [Block]
    ) {
        guard !sources.isEmpty else { return }
        blocks.append(
            .prose(
                ChatMarkdownProseRun(
                    source: sources.joined(),
                    pieces: pieces
                )
            )
        )
        sources.removeAll(keepingCapacity: true)
        pieces.removeAll(keepingCapacity: true)
    }
}

/// Source is retained for the existing selectable TextKit prose renderer.
/// Pieces keep the active streaming tail cheap and semantically decorated.
nonisolated struct ChatMarkdownProseRun: Equatable, Sendable {
    enum Piece: Equatable, Sendable {
        case text(AttributedString)
        case quote(AttributedString)
        case thematicBreak
    }

    let source: String
    let pieces: [Piece]
}

nonisolated struct ChatMarkdownCodeBlock: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case fenced
        case html
    }

    let code: String
    let language: String?
    let kind: Kind

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
    let header: [AttributedString]
    let rows: [[AttributedString]]

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
                        return String(row[column].characters)
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
