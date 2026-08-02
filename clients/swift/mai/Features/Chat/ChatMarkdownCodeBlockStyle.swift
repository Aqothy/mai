import Foundation
@preconcurrency import Highlightr
import MarkdownView
import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

/// MarkdownView's code-block layout with a streaming-friendly highlighting
/// lifecycle. Highlighting begins immediately, reuses one JavaScript engine,
/// and skips superseded requests instead of waiting for the stream to pause.
struct ChatMarkdownCodeBlockStyle: MarkdownCodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChatMarkdownCodeBlock(configuration: configuration)
    }
}

private struct ChatMarkdownCodeBlock: View {
    let configuration: MarkdownCodeBlockStyleConfiguration

    @Environment(\.colorScheme) private var colorScheme
    @State private var highlightedCode: ChatCodeHighlight?
    @State private var displayCache = ChatCodeDisplayCache()
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if let language = configuration.language {
                    Text(language)
                }

                Spacer()

                Button {
                    copyCode()
                } label: {
                    Label(
                        copied ? "Copied" : "Copy code",
                        systemImage: copied ? "checkmark" : "square.on.square"
                    )
                    .labelStyle(.iconOnly)
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Code copied" : "Copy code")
            }
            .font(.callout)
            .bold()

            ScrollView(.horizontal) {
                Group {
                    if let highlightedCode {
                        Text(
                            displayCache.displayedCode(
                                code: configuration.code,
                                highlight: highlightedCode
                            )
                        )
                    } else {
                        Text(verbatim: configuration.code)
                    }
                }
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(16)
        .lineSpacing(4)
        .font(.callout.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(.rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.quaternary)
        }
        .task(id: highlightRequest) {
            guard let highlighted = await ChatCodeHighlighter.shared.highlight(
                code: configuration.code,
                language: configuration.language,
                themeName: highlightRequest.themeName
            ) else {
                return
            }
            guard !Task.isCancelled else { return }
            highlightedCode = ChatCodeHighlight(highlighted)
        }
    }

    private var highlightRequest: ChatCodeHighlightRequest {
        ChatCodeHighlightRequest(
            code: configuration.code,
            language: configuration.language,
            themeName: colorScheme == .dark
                ? "atom-one-dark"
                : "atom-one-light"
        )
    }

    private func copyCode() {
        #if os(iOS)
            UIPasteboard.general.string = configuration.code
        #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(configuration.code, forType: .string)
        #endif

        withAnimation {
            copied = true
        }

        // Cancel any in-flight reset so a rapid second copy cannot clear the
        // fresh confirmation early.
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation {
                copied = false
            }
        }
    }
}

private struct ChatCodeHighlightRequest: Hashable {
    let code: String
    let language: String?
    let themeName: String
}

/// A highlight result paired with its plain-text source, materialized once at
/// assignment so per-render merges never re-walk the attributed characters.
private struct ChatCodeHighlight: Equatable {
    let source: String
    let attributed: AttributedString

    init(_ attributed: AttributedString) {
        self.source = String(attributed.characters)
        self.attributed = attributed
    }
}

/// Memoizes the merged display string for one (code, highlight) pair so body
/// evaluations that change neither — copy feedback, unrelated invalidations —
/// skip the O(code) merge work.
private final class ChatCodeDisplayCache {
    private var code: String?
    private var highlightSource: String?
    private var displayed: AttributedString?

    func displayedCode(
        code: String,
        highlight: ChatCodeHighlight
    ) -> AttributedString {
        if let displayed, code == self.code, highlight.source == highlightSource {
            return displayed
        }

        let merged = Self.mergedDisplayCode(code: code, highlight: highlight)
        self.code = code
        highlightSource = highlight.source
        displayed = merged
        return merged
    }

    /// Keeps the already-highlighted prefix visible while the latest source is
    /// being processed. Newly arrived characters appear immediately and gain
    /// their colors as soon as the newest highlight finishes.
    private static func mergedDisplayCode(
        code: String,
        highlight: ChatCodeHighlight
    ) -> AttributedString {
        guard code.hasPrefix(highlight.source) else {
            return AttributedString(code)
        }

        var displayedCode = highlight.attributed
        displayedCode.append(
            AttributedString(code.dropFirst(highlight.source.count))
        )
        return displayedCode
    }
}

/// Serializes access to Highlightr's JavaScript context. Cancelled tasks check
/// cancellation before doing expensive work, so queued intermediate snapshots
/// are skipped and only the newest source is highlighted after an active pass.
actor ChatCodeHighlighter {
    static let shared = ChatCodeHighlighter()

    private var highlighter: Highlightr?
    private var currentThemeName: String?
    /// Lowercased name → canonical name, cached once per highlighter instance
    /// because `supportedLanguages()` round-trips through the JavaScript
    /// engine on every call.
    private var supportedLanguagesByLowercasedName: [String: String]?

    func prepare() {
        _ = preparedHighlighter()
    }

    func highlight(
        code: String,
        language: String?,
        themeName: String
    ) -> AttributedString? {
        guard !Task.isCancelled else { return nil }
        guard let highlighter = preparedHighlighter() else { return nil }

        if currentThemeName != themeName {
            guard highlighter.setTheme(to: themeName) else { return nil }
            currentThemeName = themeName
        }

        let requestedLanguage = language?.lowercased() ?? ""
        let resolvedLanguage = resolvedLanguageName(
            for: requestedLanguage,
            using: highlighter
        )

        guard !Task.isCancelled else { return nil }
        guard let result = highlighter.highlight(code, as: resolvedLanguage) else {
            return nil
        }

        let mutableResult = NSMutableAttributedString(attributedString: result)
        mutableResult.removeAttribute(
            .font,
            range: NSRange(location: 0, length: mutableResult.length)
        )

        guard !Task.isCancelled else { return nil }
        return AttributedString(mutableResult)
    }

    private func resolvedLanguageName(
        for requestedLanguage: String,
        using highlighter: Highlightr
    ) -> String? {
        if supportedLanguagesByLowercasedName == nil {
            supportedLanguagesByLowercasedName = Dictionary(
                highlighter.supportedLanguages().map { ($0.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return supportedLanguagesByLowercasedName?[requestedLanguage]
    }

    private func preparedHighlighter() -> Highlightr? {
        if let highlighter {
            return highlighter
        }

        let highlighter = Highlightr()
        self.highlighter = highlighter
        return highlighter
    }
}
