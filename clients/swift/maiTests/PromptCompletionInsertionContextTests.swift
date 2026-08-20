import Testing
@testable import mai

struct PromptCompletionInsertionContextTests {
    @Test
    func detectsEveryTriggerAtTokenBoundaries() throws {
        let file = try #require(
            PromptCompletionInsertionContext.detect(in: "Review @Con", cursorOffset: 11)
        )
        let command = try #require(
            PromptCompletionInsertionContext.detect(in: "/comp", cursorOffset: 5)
        )
        let skill = try #require(
            PromptCompletionInsertionContext.detect(in: "Use $pdf", cursorOffset: 8)
        )

        #expect(file.kind == .workspaceFile)
        #expect(file.query(in: "Review @Con", cursorOffset: 11) == "Con")
        #expect(command.kind == .slashCommand)
        #expect(command.query(in: "/comp", cursorOffset: 5) == "comp")
        #expect(skill.kind == .skill)
        #expect(skill.query(in: "Use $pdf", cursorOffset: 8) == "pdf")
    }

    @Test
    func ignoresTriggerCharactersInsideWords() {
        #expect(
            PromptCompletionInsertionContext.detect(
                in: "person@example.com",
                cursorOffset: 18
            ) == nil
        )
        #expect(
            PromptCompletionInsertionContext.detect(
                in: "price$usd",
                cursorOffset: 9
            ) == nil
        )
    }

    @Test
    func completionUsesTheCaretInsteadOfPromptEnd() throws {
        let text = "Run /comp after this"
        let cursorOffset = "Run /comp".count
        let context = try #require(
            PromptCompletionInsertionContext.detect(
                in: text,
                cursorOffset: cursorOffset
            )
        )

        #expect(context.query(in: text, cursorOffset: cursorOffset) == "comp")
        #expect(
            context.edit(
                replacingWith: "compact",
                appendsTrailingSpace: false,
                in: text
            ) == PromptCompletionEdit(
                text: "Run /compact after this",
                cursorOffset: "Run /compact".count
            )
        )
    }

    @Test
    func preservesTextThatWasAfterAnInsertedTrigger() throws {
        let context = try #require(
            PromptCompletionInsertionContext.detect(
                in: "Review @this",
                cursorOffset: "Review @".count
            )
        )
        let editedText = "Review @Contentthis"
        let cursorOffset = "Review @Content".count

        #expect(context.query(in: editedText, cursorOffset: cursorOffset) == "Content")
        #expect(
            context.edit(
                replacingWith: "Sources/ContentView.swift",
                appendsTrailingSpace: true,
                in: editedText
            ) == PromptCompletionEdit(
                text: "Review @Sources/ContentView.swift this",
                cursorOffset: "Review @Sources/ContentView.swift ".count
            )
        )
    }

    @Test
    func characterOffsetsRemainUnicodeSafe() throws {
        let text = "✨ 请用 $pdf"
        let context = try #require(
            PromptCompletionInsertionContext.detect(
                in: text,
                cursorOffset: text.count
            )
        )

        #expect(
            context.edit(
                replacingWith: "pdf-reader",
                appendsTrailingSpace: true,
                in: text
            ) == PromptCompletionEdit(
                text: "✨ 请用 $pdf-reader ",
                cursorOffset: "✨ 请用 $pdf-reader ".count
            )
        )
    }

    @Test
    func whitespaceEndsTheActiveQuery() throws {
        let context = try #require(
            PromptCompletionInsertionContext.detect(in: "$pdf", cursorOffset: 4)
        )

        #expect(context.query(in: "$pdf notes", cursorOffset: 10) == nil)
        #expect(
            context.edit(
                replacingWith: "pdf-reader",
                appendsTrailingSpace: true,
                in: "$pdf notes"
            ) == nil
        )
    }

    @Test
    func commandsOnlyAppendSpaceWhenTheyAcceptInput() throws {
        let context = try #require(
            PromptCompletionInsertionContext.detect(in: "/com", cursorOffset: 4)
        )

        #expect(
            context.edit(
                replacingWith: "compact",
                appendsTrailingSpace: false,
                in: "/com"
            )?.text == "/compact"
        )
        #expect(
            context.edit(
                replacingWith: "review",
                appendsTrailingSpace: true,
                in: "/com"
            )?.text == "/review "
        )
    }
}
