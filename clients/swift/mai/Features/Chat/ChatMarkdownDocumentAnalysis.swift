import Markdown
import MarkdownView

/// Safety-relevant features found in an already-parsed Markdown document.
nonisolated struct ChatMarkdownDocumentAnalysis: Equatable, Sendable {
    enum PlainTextFallbackReason: String, CaseIterable, Sendable {
        case blockHTML = "block HTML"
        case inlineHTML = "inline HTML"
        case image = "image"
    }

    var containsBlockHTML = false
    var containsInlineHTML = false
    var containsImage = false

    var requiresPlainTextFallback: Bool {
        containsBlockHTML || containsInlineHTML || containsImage
    }

    var plainTextFallbackReasons: [PlainTextFallbackReason] {
        var reasons: [PlainTextFallbackReason] = []
        if containsBlockHTML {
            reasons.append(.blockHTML)
        }
        if containsInlineHTML {
            reasons.append(.inlineHTML)
        }
        if containsImage {
            reasons.append(.image)
        }
        return reasons
    }

    var plainTextFallbackDescription: String? {
        guard requiresPlainTextFallback else { return nil }
        return plainTextFallbackReasons.map(\.rawValue).joined(separator: ", ")
    }
}

/// Inspects swift-markdown syntax rather than guessing from source text.
nonisolated enum ChatMarkdownDocumentAnalyzer {
    static func analyze(_ parseResult: MarkdownParseResult) -> ChatMarkdownDocumentAnalysis {
        analyze(parseResult.document)
    }

    static func analyze(_ document: Markdown.Document) -> ChatMarkdownDocumentAnalysis {
        var walker = SafetyMarkupWalker()
        walker.visit(document)
        return walker.analysis
    }

    static func analyze(source: String) -> ChatMarkdownDocumentAnalysis {
        analyze(Markdown.Document(parsing: source))
    }
}

private nonisolated struct SafetyMarkupWalker: MarkupWalker {
    var analysis = ChatMarkdownDocumentAnalysis()

    mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) {
        analysis.containsBlockHTML = true
        descendInto(htmlBlock)
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        analysis.containsInlineHTML = true
        descendInto(inlineHTML)
    }

    mutating func visitImage(_ image: Markdown.Image) {
        analysis.containsImage = true
        descendInto(image)
    }
}
