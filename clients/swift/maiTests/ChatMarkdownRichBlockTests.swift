import Foundation
import Testing

@testable import mai

struct ChatMarkdownRichBlockTests {
    @Test
    func plannerBuildsAQuoteWithoutSelectableDecorationGlyphs() {
        let plan = ChatMarkdownRenderPlanner.plan(
            from: "> Quoted **content**."
        )

        guard case .prose(let prose) = plan.blocks.first,
            case .quote(let quote)? = prose.pieces.first
        else {
            Issue.record("Expected a quote prose piece")
            return
        }
        let text = String(quote.characters)
        #expect(text == "Quoted content.")
        #expect(text.contains("▏") == false)
        #expect(text.contains(">") == false)
    }

    @Test
    func plannerBuildsDedicatedCodeAndTableBlocks() throws {
        let source = #"""
            Intro with **formatting**.

            ```python
            def greet(name):
                return f"Hello, {name}!"
            ```

            | Item | Type | Example |
            | :--- | :---: | ---: |
            | Code | Python | `print("Hello")` |
            """#

        let plan = ChatMarkdownRenderPlanner.plan(from: source)

        #expect(plan.blocks.count == 3)
        guard case .prose(let prose) = plan.blocks[0] else {
            Issue.record("Expected prose before the rich blocks")
            return
        }
        guard case .text(let intro)? = prose.pieces.first else {
            Issue.record("Expected an ordinary prose piece")
            return
        }
        #expect(String(intro.characters) == "Intro with formatting.")

        guard case .code(let code) = plan.blocks[1] else {
            Issue.record("Expected a dedicated code block")
            return
        }
        #expect(code.language == "python")
        #expect(code.displayLanguage == "Python")
        #expect(code.kind == .fenced)
        #expect(code.code.contains("def greet"))

        guard case .table(let table) = plan.blocks[2] else {
            Issue.record("Expected a dedicated table block")
            return
        }
        #expect(table.columnCount == 3)
        #expect(table.alignments == [.leading, .center, .trailing])
        #expect(
            table.header.map { String($0.characters) } == [
                "Item", "Type", "Example",
            ])
        #expect(table.rows.count == 1)
        #expect(String(table.rows[0][2].characters) == "print(\"Hello\")")
        #expect(
            table.tabSeparatedText
                == "Item\tType\tExample\nCode\tPython\tprint(\"Hello\")"
        )
    }

    @Test
    func blockHTMLUsesAnInertCodeBlockAndInlineHTMLStaysText() {
        let source = """
            Press <kbd>Command</kbd> to continue.

            <section>
            Block HTML stays inert.
            </section>
            """
        let plan = ChatMarkdownRenderPlanner.plan(from: source)

        #expect(plan.blocks.count == 2)
        guard case .prose(let prose) = plan.blocks[0] else {
            Issue.record("Expected inline HTML to remain prose")
            return
        }
        guard case .text(let text)? = prose.pieces.first else {
            Issue.record("Expected inline HTML in an ordinary prose piece")
            return
        }
        #expect(
            String(text.characters)
                == "Press <kbd>Command</kbd> to continue."
        )

        guard case .code(let html) = plan.blocks[1] else {
            Issue.record("Expected block HTML to use an inert code block")
            return
        }
        #expect(html.displayLanguage == "HTML")
        #expect(html.kind == .html)
        #expect(html.code.contains("<section>"))
    }

    @Test
    func referenceDefinitionsKeepRichBlocksOnTheFullRenderer() {
        let source = #"""
            Intro with [documentation][docs].

            ```swift
            let value = 42
            ```

            [docs]: https://example.com
            """#
        let plan = ChatMessageTextPlanner.plan(
            messageID: "referenced-rich-message",
            role: MaidMessageRole.assistant.rawValue,
            messageTurnID: "finished-turn",
            streamingTurnID: nil,
            source: source,
            segmentCache: ChatMarkdownSegmentCache()
        )

        #expect(plan == .existingRenderer)
        #expect(
            ChatMarkdownRenderPlanner.plan(from: source).blocks.contains {
                if case .code = $0 { true } else { false }
            }
        )
    }

    @Test
    func thematicBreakUsesItsOwnFullWidthBlock() {
        let plan = ChatMarkdownRenderPlanner.plan(
            from: "Before\n\n---\n\nAfter"
        )

        #expect(plan.blocks.count == 1)
        guard case .prose(let prose) = plan.blocks[0] else {
            Issue.record("Expected one continuous prose run")
            return
        }
        #expect(prose.pieces.count == 3)
        #expect(prose.pieces.contains(.thematicBreak))
        #expect(prose.source == "Before\n\n---\n\nAfter")
    }

    @Test
    func renderPlanCacheReusesAndReplacesValues() {
        let cache = ChatMarkdownRenderCache()
        let first = cache.plan(
            messageID: "rich-message",
            source: "```swift\nlet value = 1\n```"
        )
        let repeated = cache.plan(
            messageID: "rich-message",
            source: "```swift\nlet value = 1\n```"
        )
        let replacement = cache.plan(
            messageID: "rich-message",
            source: "```swift\nlet value = 2\n```"
        )

        #expect(first == repeated)
        #expect(first != replacement)
    }

    @Test
    func highlighterPreservesCodeWhileAddingSyntaxAttributes() async throws {
        let code = "let greeting = \"Hello\""
        let highlighted = try #require(
            await ChatCodeHighlighter.shared.highlight(
                code: code,
                language: "swift",
                theme: .dark
            )
        )

        #expect(String(highlighted.characters) == code)
        #expect(highlighted.runs.count > 1)
    }
}
