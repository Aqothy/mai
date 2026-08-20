import Testing
@testable import mai

struct WorkspaceFileInsertionContextTests {
    @Test
    func detectsAtSignAtWordBoundary() {
        #expect(
            WorkspaceFileInsertionContext.insertedAtSign(
                from: "Review ",
                to: "Review @"
            ) != nil
        )
        #expect(
            WorkspaceFileInsertionContext.insertedAtSign(
                from: "",
                to: "@"
            ) != nil
        )
    }

    @Test
    func ignoresAtSignInsideWord() {
        #expect(
            WorkspaceFileInsertionContext.insertedAtSign(
                from: "person",
                to: "person@"
            ) == nil
        )
    }

    @Test
    func tracksQueryAfterTrigger() throws {
        let context = try #require(
            WorkspaceFileInsertionContext.insertedAtSign(
                from: "Review ",
                to: "Review @"
            )
        )

        #expect(context.query(in: "Review @ContentV") == "ContentV")
    }

    @Test
    func replacesMentionAndPreservesFollowingText() throws {
        let context = try #require(
            WorkspaceFileInsertionContext.insertedAtSign(
                from: "Review this",
                to: "Review @this"
            )
        )

        #expect(
            context.inserting(
                relativePath: "clients/swift/mai/ContentView.swift",
                into: "Review @Contentthis"
            ) == "Review @clients/swift/mai/ContentView.swift this"
        )
    }

    @Test
    func deletingTriggerInvalidatesContext() throws {
        let context = try #require(
            WorkspaceFileInsertionContext.insertedAtSign(
                from: "Review ",
                to: "Review @"
            )
        )

        #expect(context.query(in: "Review ") == nil)
    }

    @Test
    func whitespaceEndsCompletion() throws {
        let context = try #require(
            WorkspaceFileInsertionContext.insertedAtSign(
                from: "Review ",
                to: "Review @"
            )
        )

        #expect(context.query(in: "Review @README ") == nil)
    }

    @Test
    func characterOffsetsHandleUnicodePromptText() throws {
        let context = try #require(
            WorkspaceFileInsertionContext.insertedAtSign(
                from: "✨ ",
                to: "✨ @"
            )
        )

        #expect(
            context.inserting(relativePath: "Sources/App.swift", into: "✨ @")
                == "✨ @Sources/App.swift "
        )
    }
}
