import MarkdownView
import SwiftUI

/// Portable message-content seam for both the sandbox and the real timeline.
struct ChatMarkdownMessageView: View {
    let messageID: String
    let source: String
    let presentation: ChatMarkdownPresentation

    init(
        messageID: String,
        source: String,
        presentation: ChatMarkdownPresentation
    ) {
        self.messageID = messageID
        self.source = source
        self.presentation = presentation
    }

    var body: some View {
        ChatMarkdownMessageLifetimeView(
            source: source,
            presentation: presentation
        )
        .id(messageID)
    }
}

/// Owns exactly one streaming source for one stable message identity.
private struct ChatMarkdownMessageLifetimeView: View {
    let source: String
    let presentation: ChatMarkdownPresentation

    @State private var renderedSource: String?
    @State private var streamingSource = StreamingMarkdownSource()
    /// Once this instance has streamed, it keeps the streaming reader mounted
    /// so finishing a stream never tears down code-block state or scroll
    /// positions; `finishStreaming()` settles the reader in place instead.
    @State private var hasStreamed = false
    /// Whether `streamingSource` has been finished. A finished source stores
    /// but no longer emits text updates, so later source changes must swap in
    /// a replacement.
    @State private var streamFinished = false

    var body: some View {
        Group {
            if hasStreamed {
                StreamingMarkdownReader(streamingSource) { parseResult in
                    ChatMarkdownParsedContent(
                        parseResult: parseResult,
                        analysis: ChatMarkdownDocumentAnalyzer.analyze(parseResult),
                        presentation: presentation
                    )
                }
                .markdownStreamingRenderThrottle(presentation.streamingThrottle)
            } else {
                // `renderedSource` is nil only for the evaluations before the
                // initial onChange below fires; the raw source is a safe
                // stand-in because ChatMarkdownParsedContent's analysis still
                // catches unsanitized content.
                MarkdownReader(renderedSource ?? source) { parseResult in
                    ChatMarkdownParsedContent(
                        parseResult: parseResult,
                        analysis: ChatMarkdownDocumentAnalyzer.analyze(parseResult),
                        presentation: presentation
                    )
                }
            }
        }
        .modifier(ChatMarkdownContentStyle())
        .onChange(of: source, initial: true) { _, newSource in
            // Sanitizing happens here — once per distinct source value —
            // rather than in init, which the parent can run frequently.
            let newRenderedSource = Self.prepare(newSource)
            renderedSource = newRenderedSource
            if streamFinished {
                let replacement = StreamingMarkdownSource(newRenderedSource)
                replacement.finishStreaming()
                streamingSource = replacement
            } else if presentation.isStreaming || hasStreamed {
                streamingSource.text = newRenderedSource
            }
        }
        .onChange(of: presentation.isStreaming, initial: true) { wasStreaming, isStreaming in
            if isStreaming {
                hasStreamed = true
            }
            // The source handler above runs first in modifier order and keeps
            // renderedSource current, so transitions never re-sanitize.
            guard wasStreaming != isStreaming, let renderedSource else { return }
            if isStreaming {
                streamingSource = StreamingMarkdownSource(renderedSource)
                streamFinished = false
            } else {
                streamingSource.text = renderedSource
                streamingSource.finishStreaming()
                streamFinished = true
            }
        }
    }

    private static func prepare(_ source: String) -> String {
        ChatMarkdownSourceSanitizer.sanitize(source)
    }
}

private struct ChatMarkdownParsedContent: View {
    let parseResult: MarkdownParseResult
    let analysis: ChatMarkdownDocumentAnalysis
    let presentation: ChatMarkdownPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            #if DEBUG
                if presentation.showsDiagnostics {
                    ChatMarkdownRenderDiagnosticsBadge(
                        parseResult: parseResult,
                        analysis: analysis
                    )
                }
            #endif

            if analysis.requiresPlainTextFallback {
                Text(verbatim: parseResult.sourceSnapshot.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    #if os(iOS) || os(macOS)
                        .textSelection(.enabled)
                    #endif
            } else {
                MarkdownText(parseResult)
            }
        }
    }
}

#if DEBUG
    private struct ChatMarkdownRenderDiagnosticsBadge: View {
        let parseResult: MarkdownParseResult
        let analysis: ChatMarkdownDocumentAnalysis

        var body: some View {
            Text(summary)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: .capsule)
                .accessibilityLabel("Markdown renderer diagnostics: \(summary)")
        }

        private var summary: String {
            var fields = [
                strategyDescription,
                "\(parseResult.sourceSnapshot.text.count) chars",
            ]
            if let fallback = analysis.plainTextFallbackDescription {
                fields.append("plain text: \(fallback)")
            } else {
                fields.append("Markdown")
            }
            return fields.joined(separator: " · ")
        }

        private var strategyDescription: String {
            switch parseResult.parsingStrategy {
            case .full:
                "full"
            case .retained:
                "retained"
            case .incremental(let stablePrefixRootBlockCount):
                "incremental (\(stablePrefixRootBlockCount) stable)"
            }
        }
    }
#endif
