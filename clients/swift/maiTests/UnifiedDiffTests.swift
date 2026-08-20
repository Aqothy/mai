import Testing

@testable import mai

struct UnifiedDiffTests {
    @Test
    func parsesContextAdditionsDeletionsAndLineNumbers() throws {
        let document = UnifiedDiffParser.parse(
            """
            diff --git a/Sources/App.swift b/Sources/App.swift
            index 1111111..2222222 100644
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -10,3 +10,4 @@ struct App {
             context
            -    let value = 1
            +    let value = 2
            +    let enabled = true
             tail
            """
        )

        let file = try #require(document.files.first)
        let hunk = try #require(file.hunks.first)
        #expect(file.status == .modified)
        #expect(
            hunk.lines.map(\.kind) == [
                .context,
                .deletion,
                .addition,
                .addition,
                .context,
            ])
        #expect(hunk.lines.map(\.oldLineNumber) == [10, 11, nil, nil, 12])
        #expect(hunk.lines.map(\.newLineNumber) == [10, nil, 11, 12, 13])
        #expect(hunk.lines[2].content == "    let value = 2")
        #expect(Set(document.rows.map(\.id)).count == document.rows.count)
    }

    @Test
    func parsesMultipleFilesAndMultipleHunks() throws {
        let document = UnifiedDiffParser.parse(
            """
            diff --git a/one.txt b/one.txt
            --- a/one.txt
            +++ b/one.txt
            @@ -1 +1 @@
            -one
            +ONE
            @@ -4 +4 @@
            -four
            +FOUR
            diff --git a/two.txt b/two.txt
            --- a/two.txt
            +++ b/two.txt
            @@ -2,2 +2,2 @@
             keep
            -two
            +TWO
            """
        )

        #expect(document.files.count == 2)
        #expect(document.files[0].hunks.count == 2)
        #expect(document.files[1].hunks.count == 1)
        #expect(document.files[0].displayPath == "one.txt")
        #expect(document.files[1].displayPath == "two.txt")
    }

    @Test
    func parsesAddedDeletedRenamedAndBinaryMetadata() {
        let document = UnifiedDiffParser.parse(
            """
            diff --git a/new.txt b/new.txt
            new file mode 100644
            --- /dev/null
            +++ b/new.txt
            @@ -0,0 +1 @@
            +new
            diff --git a/deleted.txt b/deleted.txt
            deleted file mode 100644
            --- a/deleted.txt
            +++ /dev/null
            @@ -1 +0,0 @@
            -gone
            diff --git a/old name.txt b/new name.txt
            similarity index 100%
            rename from old name.txt
            rename to new name.txt
            diff --git a/image.png b/image.png
            index 1111111..2222222 100644
            Binary files a/image.png and b/image.png differ
            """
        )

        #expect(document.files.count == 4)
        #expect(document.files[0].status == .added)
        #expect(document.files[0].oldPath == nil)
        #expect(document.files[0].newPath == "new.txt")
        #expect(document.files[1].status == .deleted)
        #expect(document.files[1].oldPath == "deleted.txt")
        #expect(document.files[1].newPath == nil)
        #expect(document.files[2].status == .renamed)
        #expect(document.files[2].oldPath == "old name.txt")
        #expect(document.files[2].newPath == "new name.txt")
        #expect(document.files[3].isBinary)
    }

    @Test
    func preservesNoFinalNewlineMarkers() throws {
        let document = UnifiedDiffParser.parse(
            """
            --- a/value.txt
            +++ b/value.txt
            @@ -1 +1 @@
            -old
            \\ No newline at end of file
            +new
            \\ No newline at end of file
            """
        )

        let lines = try #require(document.files.first?.hunks.first?.lines)
        #expect(lines.map(\.kind) == [.deletion, .noNewline, .addition, .noNewline])
        #expect(lines[0].oldLineNumber == 1)
        #expect(lines[2].newLineNumber == 1)
    }

    @Test
    func repairsMalformedAndHeaderlessPatches() throws {
        let malformed = UnifiedDiffParser.parse(
            """
            --- a/partial.txt
            +++ b/partial.txt
            @@ broken header @@
             context without line ranges
            +addition without line ranges
            unsupported payload
            """
        )
        let file = try #require(malformed.files.first)
        let malformedLines = try #require(file.hunks.first?.lines)
        #expect(file.oldPath == "partial.txt")
        #expect(file.newPath == "partial.txt")
        #expect(malformedLines.map(\.kind) == [.context, .addition, .unsupported])

        let headerless = UnifiedDiffParser.parse("-before\n+after")
        let headerlessFile = try #require(headerless.files.first)
        #expect(headerlessFile.displayPath == "Partial diff")
        #expect(
            headerlessFile.hunks.first?.lines.map(\.kind)
                == [.deletion, .addition]
        )
    }

    @Test
    func keepsRowIdentityStableWhenStreamedPatchGrows() {
        let base = """
            diff --git a/one.txt b/one.txt
            --- a/one.txt
            +++ b/one.txt
            @@ -1,2 +1,2 @@
             keep
            -one
            +ONE
            """
        // Appends a line to the last hunk, a new hunk, and a new file.
        let grown = base + "\n" + [
            " tail",
            "@@ -8 +8,2 @@",
            " anchor",
            "+appended",
            "diff --git a/two.txt b/two.txt",
            "--- a/two.txt",
            "+++ b/two.txt",
            "@@ -1 +1 @@",
            "-two",
            "+TWO",
        ].joined(separator: "\n")

        let baseIDs = UnifiedDiffParser.parse(base).rows.map(\.id)
        let grownIDs = UnifiedDiffParser.parse(grown).rows.map(\.id)

        #expect(grownIDs.count > baseIDs.count)
        #expect(Array(grownIDs.prefix(baseIDs.count)) == baseIDs)
        #expect(Set(grownIDs).count == grownIDs.count)
    }

    @Test
    func assignsUniqueIdentityToDuplicatePathsAndHunkStarts() {
        let document = UnifiedDiffParser.parse(
            """
            diff --git a/dup.txt b/dup.txt
            --- a/dup.txt
            +++ b/dup.txt
            @@ -1 +1 @@
            -a
            +A
            @@ -1 +1 @@
            -b
            +B
            diff --git a/dup.txt b/dup.txt
            --- a/dup.txt
            +++ b/dup.txt
            @@ -1 +1 @@
            -c
            +C
            """
        )

        #expect(document.files.count == 2)
        #expect(Set(document.files.map(\.id)).count == 2)
        #expect(Set(document.rows.map(\.id)).count == document.rows.count)
    }

    @Test
    func adaptsCodexPatchAndACPBeforeAfterPayloads() throws {
        let codex = FileChange(
            diff: """
                @@ -1 +1 @@
                -let value = 1
                +let value = 2
                """,
            kind: MaidFileChangeKind.update.rawValue,
            movePath: nil,
            newText: nil,
            oldText: nil,
            path: "Sources/Value.swift"
        )
        let acp = FileChange(
            diff: nil,
            kind: MaidFileChangeKind.move.rawValue,
            movePath: "Sources/Renamed.swift",
            newText: "let value = 2\nlet enabled = true\n",
            oldText: "let value = 1\nlet enabled = true\n",
            path: "Sources/Original.swift"
        )

        let document = UnifiedDiffFileChangeAdapter.adapt(
            [codex, acp].map {
                UnifiedDiffSource.ToolChange($0)
            }
        )

        #expect(document.files.count == 2)
        #expect(document.files[0].displayPath == "Sources/Value.swift")
        #expect(document.files[0].hunks[0].lines.map(\.kind) == [.deletion, .addition])
        #expect(document.files[1].status == .renamed)
        #expect(document.files[1].oldPath == "Sources/Original.swift")
        #expect(document.files[1].newPath == "Sources/Renamed.swift")
        #expect(
            document.files[1].hunks[0].lines.map(\.kind) == [
                .deletion,
                .addition,
                .context,
            ])
    }

    @Test
    func adaptsFinalNewlineOnlyChangesAsChangedLines() throws {
        let change = FileChange(
            diff: nil,
            kind: MaidFileChangeKind.update.rawValue,
            movePath: nil,
            newText: "same content",
            oldText: "same content\n",
            path: "value.txt"
        )

        let document = UnifiedDiffFileChangeAdapter.adapt([
            UnifiedDiffSource.ToolChange(change)
        ])
        let lines = try #require(document.files.first?.hunks.first?.lines)

        #expect(lines.map(\.kind) == [.deletion, .addition, .noNewline])
        #expect(lines[0].oldLineNumber == 1)
        #expect(lines[1].newLineNumber == 1)
    }

}
