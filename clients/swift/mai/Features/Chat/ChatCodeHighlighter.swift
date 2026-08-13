import Foundation
@preconcurrency import Highlighter

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

nonisolated enum ChatCodeHighlightTheme: String, Hashable, Sendable {
    case light
    case dark

    var highlighterThemeName: String {
        switch self {
        case .light:
            "xcode"
        case .dark:
            "atom-one-dark"
        }
    }
}

/// Reuses and serializes access to HighlighterSwift's JavaScript context.
/// Syntax work never runs on the main actor. Recent finished values stay
/// process-wide so List recycling does not repeatedly execute the same JavaScript.
actor ChatCodeHighlighter {
    static let shared = ChatCodeHighlighter()

    private struct Key: Hashable {
        let code: String
        let language: String?
        let theme: ChatCodeHighlightTheme
    }

    private struct Entry {
        let value: AttributedString
        let retainedBytes: Int
    }

    /// Highlight attributes are much denser than Markdown source. This keeps
    /// recent remounts hot without letting code opened across many chats grow
    /// for the lifetime of the process.
    private static let maximumRetainedBytes = 8 * 1_024 * 1_024

    private var highlighter: Highlighter?
    private var configuredTheme: ChatCodeHighlightTheme?
    private var supportedLanguages: Set<String> = []
    private var entries: [Key: Entry] = [:]
    private var insertionOrder: [Key] = []
    private var retainedBytes = 0

    func highlight(
        code: String,
        language: String?,
        theme: ChatCodeHighlightTheme
    ) -> AttributedString? {
        guard !code.isEmpty else { return AttributedString() }

        let normalizedLanguage = Self.normalizedLanguage(language)
        let key = Key(
            code: code,
            language: normalizedLanguage,
            theme: theme
        )
        if let cached = entries[key] {
            return cached.value
        }

        guard let highlighter = configuredHighlighter(for: theme) else {
            return nil
        }
        let language = normalizedLanguage.flatMap {
            supportedLanguages.contains($0) ? $0 : nil
        }
        guard let highlighted = highlighter.highlight(code, as: language) else {
            return nil
        }

        // SwiftUI supplies the Dynamic Type-aware monospaced font and line
        // spacing. HighlighterSwift contributes syntax foreground colors only.
        let mutable = NSMutableAttributedString(attributedString: highlighted)
        let range = NSRange(location: 0, length: mutable.length)
        mutable.removeAttribute(.font, range: range)
        mutable.removeAttribute(.backgroundColor, range: range)
        mutable.removeAttribute(.paragraphStyle, range: range)
        let value = AttributedString(mutable)
        insert(value, code: code, for: key)
        return value
    }

    private func insert(
        _ value: AttributedString,
        code: String,
        for key: Key
    ) {
        let entry = Entry(
            value: value,
            retainedBytes: Self.estimatedRetainedBytes(
                code: code,
                value: value
            )
        )
        guard entry.retainedBytes <= Self.maximumRetainedBytes else { return }

        entries[key] = entry
        insertionOrder.append(key)
        retainedBytes += entry.retainedBytes

        while retainedBytes > Self.maximumRetainedBytes,
            !insertionOrder.isEmpty
        {
            let oldestKey = insertionOrder.removeFirst()
            guard let removed = entries.removeValue(forKey: oldestKey) else {
                continue
            }
            retainedBytes -= removed.retainedBytes
        }
    }

    private static func estimatedRetainedBytes(
        code: String,
        value: AttributedString
    ) -> Int {
        code.utf8.count * 2
            + value.characters.count * 2
            + value.runs.count * 96
    }

    private func configuredHighlighter(
        for theme: ChatCodeHighlightTheme
    ) -> Highlighter? {
        if highlighter == nil {
            highlighter = Highlighter()
            highlighter?.ignoreIllegals = true
            supportedLanguages = Set(
                highlighter?.supportedLanguages().map { $0.lowercased() } ?? []
            )
        }
        guard let highlighter else { return nil }

        if configuredTheme != theme {
            guard highlighter.setTheme(theme.highlighterThemeName) else {
                return nil
            }
            configuredTheme = theme
        }
        return highlighter
    }

    private static func normalizedLanguage(_ language: String?) -> String? {
        guard let language = language?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased(), !language.isEmpty else {
            return nil
        }

        return switch language {
        case "c++": "cpp"
        case "cs": "csharp"
        case "golang": "go"
        case "js", "jsx": "javascript"
        case "md": "markdown"
        case "objective-c": "objectivec"
        case "py": "python"
        case "rb": "ruby"
        case "sh", "shell": "bash"
        case "ts", "tsx": "typescript"
        case "yml": "yaml"
        default: language
        }
    }
}
