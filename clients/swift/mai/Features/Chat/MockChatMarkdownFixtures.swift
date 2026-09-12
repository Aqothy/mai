/// Deterministic Markdown content used by `MockChatView` to exercise the
/// production renderer without coupling fixture construction to view code.
enum MockChatMarkdownFixtures {
    struct Sample: Hashable, Identifiable, Sendable {
        let id: String
        let label: String
        let markdown: String
    }

    static let componentCatalog: String = [
        prose,
        headings,
        inlineStyles,
        lists,
        safeLinks,
        blockquotes,
        fencedCode,
        horizontalRule,
        wideTable,
        breaksAndEscapes,
    ].joined(separator: "\n\n")

    /// Focused rich-block fixture for the native renderer.
    static let richBlocks = #"""
        # Rich blocks

        ## Code block

        ```python
        def greet(name):
            return f"Hello, {name}!"

        print(greet("World"))
        ```

        A long source line should scroll horizontally instead of wrapping:

        ```swift
        let endpoint = "https://example.com/a/very/long/path?alpha=11111111111111111111&beta=22222222222222222222&gamma=33333333333333333333"
        ```

        ## Table

        | Item | Type | Example | Behavior |
        | :--- | :---: | :--- | ---: |
        | Code | Python | `print("Hello")` | highlighted |
        | HTML | Element | `<div>` | inert text |
        | Wide content | Markdown | `![Alt text](image.png)` | horizontal scroll |

        ## HTML block

        <section>
          <strong>HTML remains inert source.</strong>
        </section>
        """#

    static let codeHeavy: String = [
        codeHeavyIntroduction,
        codeHeavySwift,
        codeHeavyTypeScript,
        codeHeavyPython,
        codeHeavyRust,
        codeHeavyKotlin,
        codeHeavyGo,
        codeHeavyBash,
        codeHeavyYAML,
        codeHeavyXML,
        codeHeavyCSS,
        codeHeavyJSON,
        codeHeavyPlainText,
        codeHeavySQL,
        codeHeavyLongLine,
        codeHeavyConclusion,
    ].joined(separator: "\n\n")

    static let swiftHighlighting = codeHeavySwift

    static let malformedSamples: [Sample] = [
        Sample(
            id: "unclosed-fence",
            label: "Unclosed code fence",
            markdown: #"""
                The provider has started a Swift example, but the closing fence has not arrived.

                ```swift
                struct PendingReply: Sendable {
                    let id: String
                    var markdown: String

                    mutating func append(_ chunk: String) {
                        markdown.append(contentsOf: chunk)
                    }
                }
                """#
        ),
        Sample(
            id: "incomplete-link",
            label: "Incomplete link",
            markdown: """
                The documentation is still arriving: [Markdown reference](https://example.com/docs/mark
                """
        ),
        Sample(
            id: "unclosed-emphasis",
            label: "Unclosed emphasis",
            markdown: """
                This response ends with **strong text that is not finished and _nested emphasis
                """
        ),
        Sample(
            id: "partial-table",
            label: "Partial table",
            markdown: """
                | Renderer | Streaming | Tables |
                | --- | :---: |
                | Native | yes
                """
        ),
    ]

    static let unsupportedSamples: [Sample] = [
        Sample(
            id: "raw-html",
            label: "Raw HTML",
            markdown: #"""
                Raw HTML is displayed as an inert HTML code block:

                <section><strong>This stays code.</strong></section>
                <script>alert("never executed")</script>
                """#
        ),
        Sample(
            id: "inline-html",
            label: "Inline HTML",
            markdown: """
                Inline HTML must remain inert and readable:
                press <kbd>Command</kbd> + <kbd>Return</kbd> to continue.
                """
        ),
        Sample(
            id: "image",
            label: "Image syntax",
            markdown: """
                Embedded media is outside this renderer's scope:

                ![A deliberately unavailable fixture image](https://example.invalid/mock-chat.png)
                """
        ),
        Sample(
            id: "links",
            label: "Non-navigating links",
            markdown: """
                Link labels still render: [Unsafe destination](javascript:alert%281%29)

                HTTPS links open interactively: [Documentation](https://example.com/safe)
                """
        ),
        Sample(
            id: "mixed-extensions",
            label: "Math and read-only extensions",
            markdown: #"""
                Unsupported math remains selectable literal source:

                $$
                \int_0^1 x^2\,dx = \frac{1}{3}
                $$

                Mermaid remains a selectable fenced code block and is never executed:

                ```mermaid
                graph TD
                    Input --> Parser
                    Parser --> SwiftUI
                ```

                Task markers render as read-only status icons:

                - [x] Parsed
                - [ ] Never interactive
                """#
        ),
        Sample(
            id: "iframe",
            label: "Iframe HTML",
            markdown: #"""
                Iframes remain inert and display as HTML code:

                <iframe src="https://example.com/embed"></iframe>
                """#
        ),
    ]

    static let malformedMarkdown = catalog(
        title: "Malformed and incomplete Markdown",
        samples: malformedSamples
    )

    static let unclosedFence =
        malformedSamples.first { $0.id == "unclosed-fence" }?.markdown ?? ""

    static let unsupportedMarkdown = catalog(
        title: "Inert Markdown sources",
        samples: unsupportedSamples
    )

    /// A realistically large response assembled once from bounded sections.
    /// Joining an array avoids repeated copies from a long `+` chain.
    static let longMarkdown: String = {
        var sections = [String]()
        sections.reserveCapacity(16)
        sections.append(
            """
            # Long Markdown response

            This fixture approximates a long assistant answer. It repeats realistic prose,
            decisions, lists, and small code fragments while retaining one stable String value.
            """
        )

        for sectionNumber in 1...10 {
            sections.append(
                """
                ## Analysis section \(sectionNumber)

                Section \(sectionNumber) explains a small implementation decision in enough
                detail to wrap across several lines at common chat widths. The renderer should
                keep scrolling responsive, preserve selection, and avoid changing the identity
                of neighboring messages when only the streamed row changes.

                - Keep parsing separate from transcript layout.
                - Treat incomplete input as an expected streaming state.
                  - Preserve the exact source received so far.
                  - Replace only the active message's rendered content.
                - Prefer a readable fallback over a fragile special case.

                ```swift
                let section = \(sectionNumber)
                let status = section.isMultiple(of: 2) ? "even" : "odd"
                print("Section \\(section) is \\(status)")
                ```

                > Checkpoint \(sectionNumber): scrolling up should suspend bottom-following,
                > while returning to the end should resume it.
                """
            )
        }

        sections.append("## Full component catalogue\n\n\(componentCatalog)")
        sections.append("## Code-heavy appendix\n\n\(codeHeavy)")
        sections.append(
            """
            ## Conclusion

            The end marker makes it easy to confirm that a large message remains selectable,
            accessible, and correctly positioned after every section has rendered.
            """
        )
        return sections.joined(separator: "\n\n")
    }()

    /// A complete response whose early prefixes are deliberately invalid
    /// Markdown while chunks are arriving.
    static func streamedReply(prompt: String) -> String {
        #"""
        ## Mock streamed reply

        You asked: “\#(prompt)”

        This response mixes **strong text**, *emphasis*, ~~a revised phrase~~, and
        `inline code` so delimiter boundaries are exercised during streaming.

        ### Proposed approach

        1. Preserve each incoming chunk exactly.
        2. Coalesce only rendering work during rapid bursts.
           - Keep the message identifier stable.
           - Keep transcript scrolling outside the Markdown renderer.
        3. Render the final source with the same path used for stored messages.

        > Partial Markdown is normal while a provider is streaming.
        > A readable temporary fallback is better than dropping content.

        ```swift
        struct StreamAccumulator {
            private(set) var source = ""

            mutating func receive(_ chunk: String) {
                source.append(contentsOf: chunk)
            }
        }
        ```

        A fence without a language should remain useful:

        ```
        GET /v1/mock-chat
        x-stream-profile: deterministic
        ```

        | Stage | Input | Expected result |
        | :--- | :--- | :--- |
        | Prefix | `**par` | readable incomplete content |
        | Update | `tial**` | completed strong emphasis |
        | Finish | full source | stable final rendering |

        Safe links such as [the example documentation](https://example.com/docs) should be
        visibly interactive, while URL policy remains outside parsing.

        ---

        The reply is complete. A final soft
        line break and a hard break follow.\
        This sentence begins after the hard break.
        """#
    }

    private static func catalog(title: String, samples: [Sample]) -> String {
        var sections = [String]()
        sections.reserveCapacity(samples.count + 1)
        sections.append("# \(title)")
        sections.append(
            contentsOf: samples.map { sample in
                "## \(sample.label)\n\n\(sample.markdown)"
            }
        )
        return sections.joined(separator: "\n\n")
    }

    private static let prose = """
        # Prose and paragraphs

        A compact paragraph should read naturally in a chat bubble. It includes punctuation,
        Unicode such as café, naïve, em dashes — and emoji 🧪 without losing characters.

        A second paragraph verifies vertical rhythm. Long prose should wrap at word boundaries,
        remain selectable, and adapt to Dynamic Type without requiring a fixed width.
        """

    private static let headings = """
        # Heading level one
        ## Heading level two
        ### Heading level three
        #### Heading level four
        ##### Heading level five
        ###### Heading level six
        """

    private static let inlineStyles = #"""
        ## Inline styles

        This has *emphasis*, _alternate emphasis_, **strong text**, __alternate strong text__,
        ***combined emphasis***, ~~strikethrough~~, and `let answer = 42` inline code.

        Delimiters beside punctuation should stay predictable: (**bold**), *italic*, and
        `code.with.dots()`.
        """#

    private static let lists = """
        ## Lists

        - First unordered item
        - Second unordered item with enough prose to wrap onto another visual line at a narrow width
          - Nested unordered item
            1. Ordered item nested two levels deep
            2. A second nested ordered item
          - Nested sibling
        - Final unordered item

        1. First ordered item
        2. Second ordered item
           1. Nested ordered item
           2. Another nested ordered item
        3. Final ordered item with `inline code`
        """

    private static let safeLinks = """
        ## Safe links

        Visit [Example](https://example.com), open the
        [documentation with a fragment](https://example.com/docs?q=markdown#streaming), or inspect
        an autolink: <https://example.com/reference>.
        """

    private static let blockquotes = """
        ## Blockquotes

        > A single-line quotation should be visually distinct from surrounding prose.

        > A multi-line quotation can contain **strong text** and `inline code`.
        >
        > It can also contain a second paragraph.
        >
        > > Nested quotations should degrade gracefully if custom nesting is unavailable.
        """

    private static let fencedCode = #"""
        ## Fenced code

        ```swift
        actor ReplyBuffer {
            private var chunks: [String] = []

            func append(_ chunk: String) {
                chunks.append(chunk)
            }

            var source: String {
                chunks.joined()
            }
        }
        ```

        A fence without a language:

        ```
        alpha -> beta -> gamma
        Tabs	and repeated spaces    should remain visible.
        ```

        A long code line should scroll horizontally instead of becoming unreadable:

        ```text
        https://example.com/a/very/long/path?alpha=11111111111111111111&beta=22222222222222222222&gamma=33333333333333333333&delta=44444444444444444444&epsilon=55555555555555555555
        ```
        """#

    private static let horizontalRule = """
        ## Horizontal rule

        Content before the rule.

        ---

        Content after the rule.
        """

    private static let wideTable = """
        ## Wide table

        | Feature | Plain text | Streaming | Selection | Accessibility | Light mode | Dark mode | Notes |
        | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
        | Paragraphs | yes | yes | yes | required | verify | verify | wraps naturally |
        | Fenced code | yes | partial-safe | yes | labelled | verify | verify | horizontal scrolling |
        | Tables | native | incremental | yes | readable | verify | verify | intentionally wide |
        """

    private static let breaksAndEscapes = [
        """
        ## Escapes and line breaks

        Soft-break first line
        soft-break second line should normally remain in the same paragraph.
        """,
        "Hard-break first line ends with two spaces.  \nHard-break second line starts here.",
        """
        Escaped markers stay literal: \\*asterisks\\*, \\_underscores\\_, \\[brackets\\],
        \\# hash, \\> quote marker, and \\\\ backslash.
        """,
    ].joined(separator: "\n\n")

    private static let codeHeavyIntroduction = """
        # Code-heavy response

        The blocks below exercise language labels, selection, copying, long horizontal content,
        repeated fences, and prose transitions between code samples.
        """

    private static let codeHeavySwift = #"""
        ## Swift actor

        ```swift
        actor MarkdownRenderStore {
            struct Entry: Sendable {
                let messageID: String
                let version: Int
                let source: String
            }

            private var entries: [String: Entry] = [:]

            func value(for messageID: String, version: Int) -> Entry? {
                guard let entry = entries[messageID], entry.version == version else {
                    return nil
                }
                return entry
            }

            func insert(_ entry: Entry) {
                entries[entry.messageID] = entry
            }
        }
        ```
        """#

    private static let codeHeavyTypeScript = #"""
        ## TypeScript event reducer

        ```typescript
        type StreamEvent =
          | { type: "delta"; sequence: number; text: string }
          | { type: "complete"; checksum: string };

        export function applyEvent(source: string, event: StreamEvent): string {
          switch (event.type) {
            case "delta":
              return `${source}${event.text}`;
            case "complete":
              console.info("stream complete", { checksum: event.checksum });
              return source;
          }
        }
        ```
        """#

    private static let codeHeavyPython = #"""
        ## Python async collector

        ```python
        from collections.abc import AsyncIterator
        from dataclasses import dataclass

        @dataclass(frozen=True, slots=True)
        class Chunk:
            sequence: int
            text: str

        async def collect(stream: AsyncIterator[Chunk]) -> str:
            parts: list[str] = []
            async for chunk in stream:
                if chunk.sequence < 0:
                    raise ValueError(f"invalid sequence: {chunk.sequence}")
                parts.append(chunk.text)
            return "".join(parts)
        ```
        """#

    private static let codeHeavyRust = #"""
        ## Rust stream events

        ```rust
        #[derive(Debug, Clone)]
        enum StreamEvent<'a> {
            Delta { sequence: u64, text: &'a str },
            Complete { checksum: String },
        }

        fn append_delta(output: &mut String, event: StreamEvent<'_>) {
            match event {
                StreamEvent::Delta { sequence, text } if sequence > 0 => output.push_str(text),
                StreamEvent::Complete { checksum } => println!("complete: {checksum}"),
                _ => {}
            }
        }
        ```
        """#

    private static let codeHeavyKotlin = #"""
        ## Kotlin sealed events

        ```kotlin
        sealed interface StreamEvent {
            data class Delta(val sequence: Long, val text: String) : StreamEvent
            data class Complete(val checksum: String) : StreamEvent
        }

        fun reduce(source: String, event: StreamEvent): String = when (event) {
            is StreamEvent.Delta -> source + event.text
            is StreamEvent.Complete -> source.also {
                println("complete: ${event.checksum}")
            }
        }
        ```
        """#

    private static let codeHeavyGo = #"""
        ## Go channel consumer

        ```go
        type Event struct {
            Sequence int    `json:"sequence"`
            Delta    string `json:"delta"`
        }

        func consume(ctx context.Context, events <-chan Event) (string, error) {
            var output strings.Builder
            for {
                select {
                case <-ctx.Done():
                    return "", ctx.Err()
                case event, ok := <-events:
                    if !ok { return output.String(), nil }
                    output.WriteString(event.Delta)
                }
            }
        }
        ```
        """#

    private static let codeHeavyBash = #"""
        ## Bash stream inspection

        ```bash
        #!/usr/bin/env bash
        set -euo pipefail

        input_path="${1:-/dev/stdin}"
        sequence=0
        while IFS= read -r chunk; do
          ((sequence += 1))
          printf '[%04d] %s\n' "$sequence" "$chunk"
        done < "$input_path"
        ```
        """#

    private static let codeHeavyYAML = #"""
        ## YAML renderer configuration

        ```yaml
        renderer:
          throttle_ms: 50
          themes:
            light: atom-one-light
            dark: atom-one-dark
          features:
            fenced_code: true
            tables: true
        languages:
          - swift
          - typescript
          - python
          - rust
        ```
        """#

    private static let codeHeavyXML = #"""
        ## XML markup

        ```xml
        <?xml version="1.0" encoding="UTF-8"?>
        <message id="fixture-assistant-001" role="assistant">
          <stream sequence="42" final="false">
            <![CDATA[A chunk with **partial Markdown]]>
          </stream>
        </message>
        ```
        """#

    private static let codeHeavyCSS = #"""
        ## CSS code presentation

        ```css
        .code-block[data-language="swift"] {
          color: var(--syntax-foreground);
          background: color-mix(in srgb, var(--surface) 92%, black);
          border: 1px solid rgb(128 128 128 / 24%);
          overflow-x: auto;
        }

        @media (prefers-color-scheme: dark) {
          .code-block { --syntax-foreground: #abb2bf; }
        }
        ```
        """#

    private static let codeHeavyJSON = #"""
        ## JSON payload

        ```json
        {
          "type": "message.delta",
          "message_id": "fixture-assistant-001",
          "sequence": 42,
          "delta": {
            "text": "A chunk with **partial Markdown",
            "is_final": false
          },
          "diagnostics": {
            "received_at": "2026-07-31T12:34:56Z",
            "profile": "daemon"
          }
        }
        ```
        """#

    private static let codeHeavyPlainText = #"""
        ## Unlabelled diagnostic output

        ```
        [stream] connected
        [stream] sequence=40 bytes=17 render=pending
        [stream] sequence=41 bytes=3 render=coalesced
        [stream] sequence=42 bytes=29 render=committed
        [stream] complete checksum=fixture
        ```
        """#

    private static let codeHeavySQL = #"""
        ## SQL query

        ```sql
        SELECT
            message_id,
            MAX(sequence) AS latest_sequence,
            SUM(LENGTH(delta)) AS received_bytes
        FROM streamed_message_events
        WHERE thread_id = 'mock-thread'
        GROUP BY message_id
        ORDER BY latest_sequence DESC;
        ```
        """#

    private static let codeHeavyLongLine = #"""
        ## Long lines and delimiter-like content

        ```text
        debug event=message.delta thread=mock-thread message=fixture-assistant-001 sequence=0000042 payload=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 path=/an/intentionally/long/path/that/should/not/wrap/aggressively/in/a/code/block
        literal delimiters inside code: **strong?** _emphasis?_ ~~strike?~~ [link?](https://example.com) <html?>
        ```
        """#

    private static let codeHeavyConclusion = """
        ## After the code

        Prose after the final fence confirms that the renderer closes code-block presentation and
        returns to the normal text style.
        """
}

enum MockChatStreamProfile: String, CaseIterable, Identifiable, Sendable {
    case rapidBurst
    case readableTokens
    case daemonCadence
    case slowInspection

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rapidBurst:
            "Rapid burst"
        case .readableTokens:
            "Readable tokens"
        case .daemonCadence:
            "Daemon cadence"
        case .slowInspection:
            "Slow inspection"
        }
    }

    var detail: String {
        switch self {
        case .rapidBurst:
            "3 ms chunks, rendered at most every 50 ms"
        case .readableTokens:
            "55 ms token-like chunks for normal visual checks"
        case .daemonCadence:
            "200 ms event-sized chunks matching a slower provider"
        case .slowInspection:
            "700 ms chunks for inspecting incomplete Markdown states"
        }
    }

    var delay: Duration {
        switch self {
        case .rapidBurst:
            .milliseconds(3)
        case .readableTokens:
            .milliseconds(55)
        case .daemonCadence:
            .milliseconds(200)
        case .slowInspection:
            .milliseconds(700)
        }
    }

    /// Repeating character counts. Every pattern starts with one character
    /// so a source beginning with `##`, `**`, or ``` enters an incomplete
    /// delimiter state before its next chunk arrives.
    var chunkPattern: [Int] {
        switch self {
        case .rapidBurst:
            [1, 2, 5, 3, 8, 13, 4, 21]
        case .readableTokens:
            [1, 3, 2, 7, 5, 11, 4, 17]
        case .daemonCadence:
            [1, 19, 7, 31, 13, 43, 5, 23]
        case .slowInspection:
            [1, 8, 13, 21, 34, 5, 55]
        }
    }
}

enum MockChatMarkdownStream {
    /// Splits at extended-grapheme boundaries, never normalizes whitespace,
    /// and intentionally ignores Markdown token boundaries.
    static func chunks(
        source: String,
        profile: MockChatStreamProfile
    ) -> [String] {
        guard !source.isEmpty else { return [] }

        let pattern = profile.chunkPattern
        let averageChunkSize = pattern.reduce(0, +) / pattern.count
        var result = [String]()
        result.reserveCapacity(source.count / averageChunkSize + 1)

        var lowerBound = source.startIndex
        var patternIndex = 0
        while lowerBound < source.endIndex {
            let chunkSize = pattern[patternIndex % pattern.count]
            let upperBound =
                source.index(
                    lowerBound,
                    offsetBy: chunkSize,
                    limitedBy: source.endIndex
                ) ?? source.endIndex
            result.append(String(source[lowerBound..<upperBound]))
            lowerBound = upperBound
            patternIndex += 1
        }
        return result
    }

}
