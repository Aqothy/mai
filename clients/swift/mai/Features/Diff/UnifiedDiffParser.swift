nonisolated enum UnifiedDiffParser {
    nonisolated static func parse(_ patch: String) -> UnifiedDiffDocument {
        UnifiedDiffDocument(files: parseFiles(patch))
    }

    /// Returned files carry placeholder ids; UnifiedDiffDocument.init assigns
    /// the structural identity.
    nonisolated static func parseFiles(_ patch: String) -> [UnifiedDiffFile] {
        var parser = Parser(patch: patch)
        return parser.parse()
    }

    private struct Parser {
        private let lines: [Substring]
        private var files: [UnifiedDiffFile] = []
        private var file: FileBuilder?
        private var hunk: HunkBuilder?

        init(patch: String) {
            let normalized =
                if patch.contains("\r") {
                    patch.replacing("\r\n", with: "\n").replacing("\r", with: "\n")
                } else {
                    patch
                }
            var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            if normalized.hasSuffix("\n") {
                lines.removeLast()
            }
            self.lines = lines
        }

        mutating func parse() -> [UnifiedDiffFile] {
            var index = 0
            while index < lines.count {
                let line = String(lines[index])
                let nextLine =
                    lines.index(after: index) < lines.endIndex
                    ? String(lines[lines.index(after: index)])
                    : nil

                if line.hasPrefix("diff --git ") {
                    finishFile()
                    let paths = UnifiedDiffParser.gitHeaderPaths(line)
                    startFile(oldPath: paths.oldPath, newPath: paths.newPath)
                } else if isPathHeaderPair(line, nextLine),
                    hunk == nil || hunk?.isCompleteForBoundary == true
                {
                    if file?.sawPathHeader == true || file?.hunks.isEmpty == false {
                        finishFile()
                    } else {
                        finishHunk()
                    }
                    ensureFile()
                    file?.oldPath = UnifiedDiffParser.headerPath(line, prefix: "--- ")
                    file?.newPath = UnifiedDiffParser.headerPath(
                        nextLine ?? "",
                        prefix: "+++ "
                    )
                    file?.sawOldPathHeader = true
                    file?.sawNewPathHeader = true
                    index += 1
                } else if line.hasPrefix("@@") {
                    finishHunk()
                    ensureFile()
                    hunk = HunkBuilder(parsedHeader: UnifiedDiffParser.hunkHeader(line))
                } else if hunk != nil {
                    appendHunkLine(line)
                } else {
                    parseOutsideHunk(line)
                }

                index += 1
            }

            finishFile()
            return files
        }

        private mutating func isPathHeaderPair(_ line: String, _ nextLine: String?) -> Bool {
            line.hasPrefix("--- ") && nextLine?.hasPrefix("+++ ") == true
        }

        private mutating func parseOutsideHunk(_ line: String) {
            if line.hasPrefix("--- ") {
                ensureFile()
                file?.oldPath = UnifiedDiffParser.headerPath(line, prefix: "--- ")
                file?.sawOldPathHeader = true
                return
            }
            if line.hasPrefix("+++ ") {
                ensureFile()
                file?.newPath = UnifiedDiffParser.headerPath(line, prefix: "+++ ")
                file?.sawNewPathHeader = true
                return
            }
            if line.hasPrefix("new file mode ") {
                ensureFile()
                file?.explicitStatus = .added
                file?.metadataLines.append(line)
                return
            }
            if line.hasPrefix("deleted file mode ") {
                ensureFile()
                file?.explicitStatus = .deleted
                file?.metadataLines.append(line)
                return
            }
            if line.hasPrefix("rename from ") {
                ensureFile()
                file?.explicitStatus = .renamed
                file?.oldPath = UnifiedDiffParser.renamePath(line, prefix: "rename from ")
                file?.metadataLines.append(line)
                return
            }
            if line.hasPrefix("rename to ") {
                ensureFile()
                file?.explicitStatus = .renamed
                file?.newPath = UnifiedDiffParser.renamePath(line, prefix: "rename to ")
                file?.metadataLines.append(line)
                return
            }
            if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                ensureFile()
                file?.isBinary = true
                file?.metadataLines.append(line)
                return
            }
            if line.hasPrefix("index ")
                || line.hasPrefix("old mode ")
                || line.hasPrefix("new mode ")
                || line.hasPrefix("similarity index ")
                || line.hasPrefix("dissimilarity index ")
            {
                ensureFile()
                file?.metadataLines.append(line)
                return
            }
            if line.isEmpty {
                return
            }
            if file?.isBinary == true {
                return
            }
            if line.first == "+"
                || line.first == "-"
                || line.first == " "
                || line.first == "\\"
            {
                ensureFile()
                hunk = HunkBuilder(
                    parsedHeader: HunkHeader(
                        raw: "",
                        oldStart: nil,
                        oldCount: nil,
                        newStart: nil,
                        newCount: nil
                    )
                )
                appendHunkLine(line)
                return
            }

            ensureFile()
            file?.metadataLines.append(line)
        }

        private mutating func appendHunkLine(_ rawLine: String) {
            hunk?.append(rawLine)
        }

        private mutating func startFile(oldPath: String?, newPath: String?) {
            file = FileBuilder(oldPath: oldPath, newPath: newPath)
        }

        private mutating func ensureFile() {
            guard file == nil else { return }
            startFile(oldPath: nil, newPath: nil)
        }

        private mutating func finishHunk() {
            guard let hunk else { return }
            file?.hunks.append(hunk.build())
            self.hunk = nil
        }

        private mutating func finishFile() {
            finishHunk()
            guard let file else { return }
            files.append(file.build())
            self.file = nil
        }
    }

    private struct FileBuilder {
        var oldPath: String?
        var newPath: String?
        var explicitStatus: UnifiedDiffFile.Status?
        var isBinary = false
        var sawOldPathHeader = false
        var sawNewPathHeader = false
        var metadataLines: [String] = []
        var hunks: [UnifiedDiffHunk] = []

        init(oldPath: String? = nil, newPath: String? = nil) {
            self.oldPath = oldPath
            self.newPath = newPath
        }

        var sawPathHeader: Bool {
            sawOldPathHeader || sawNewPathHeader
        }

        func build() -> UnifiedDiffFile {
            UnifiedDiffFile(
                id: .placeholder,
                oldPath: oldPath,
                newPath: newPath,
                status: status,
                isBinary: isBinary,
                metadataLines: metadataLines,
                hunks: hunks
            )
        }

        private var status: UnifiedDiffFile.Status {
            if let explicitStatus {
                return explicitStatus
            }
            if sawOldPathHeader, oldPath == nil, newPath != nil {
                return .added
            }
            if sawNewPathHeader, newPath == nil, oldPath != nil {
                return .deleted
            }
            if let oldPath, let newPath, oldPath != newPath {
                return .renamed
            }
            if oldPath != nil || newPath != nil || !hunks.isEmpty || !metadataLines.isEmpty {
                return .modified
            }
            return .unknown
        }
    }

    private struct HunkBuilder {
        let header: HunkHeader
        var lines: [UnifiedDiffLine] = []
        var oldLine: Int?
        var newLine: Int?
        var consumedOldLines = 0
        var consumedNewLines = 0

        init(parsedHeader: HunkHeader) {
            header = parsedHeader
            oldLine = parsedHeader.oldStart
            newLine = parsedHeader.newStart
        }

        var isCompleteForBoundary: Bool {
            guard let oldCount = header.oldCount, let newCount = header.newCount else {
                return true
            }
            return consumedOldLines >= oldCount && consumedNewLines >= newCount
        }

        mutating func append(_ rawLine: String) {
            let kind: UnifiedDiffLine.Kind
            let content: String
            let oldLineNumber: Int?
            let newLineNumber: Int?

            if rawLine.hasPrefix("\\ No newline at end of file") {
                kind = .noNewline
                content = "No newline at end of file"
                oldLineNumber = nil
                newLineNumber = nil
            } else {
                switch rawLine.first {
                case " ":
                    kind = .context
                    content = String(rawLine.dropFirst())
                    oldLineNumber = oldLine
                    newLineNumber = newLine
                    oldLine = oldLine.map { $0 + 1 }
                    newLine = newLine.map { $0 + 1 }
                    consumedOldLines += 1
                    consumedNewLines += 1
                case "+":
                    kind = .addition
                    content = String(rawLine.dropFirst())
                    oldLineNumber = nil
                    newLineNumber = newLine
                    newLine = newLine.map { $0 + 1 }
                    consumedNewLines += 1
                case "-":
                    kind = .deletion
                    content = String(rawLine.dropFirst())
                    oldLineNumber = oldLine
                    newLineNumber = nil
                    oldLine = oldLine.map { $0 + 1 }
                    consumedOldLines += 1
                default:
                    kind = .unsupported
                    content = rawLine
                    oldLineNumber = nil
                    newLineNumber = nil
                }
            }

            lines.append(
                UnifiedDiffLine(
                    id: .placeholder,
                    kind: kind,
                    content: content,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: newLineNumber,
                    attributedContent: nil
                )
            )
        }

        func build() -> UnifiedDiffHunk {
            UnifiedDiffHunk(
                id: .placeholder,
                header: header.raw,
                oldStart: header.oldStart,
                oldCount: header.oldCount,
                newStart: header.newStart,
                newCount: header.newCount,
                lines: lines
            )
        }
    }

    private struct HunkHeader {
        let raw: String
        let oldStart: Int?
        let oldCount: Int?
        let newStart: Int?
        let newCount: Int?
    }

    private static func hunkHeader(_ raw: String) -> HunkHeader {
        let fields = raw.split(separator: " ", omittingEmptySubsequences: true)
        let oldRange = fields.count > 1 ? range(fields[1], prefix: "-") : nil
        let newRange = fields.count > 2 ? range(fields[2], prefix: "+") : nil
        return HunkHeader(
            raw: raw,
            oldStart: oldRange?.start,
            oldCount: oldRange?.count,
            newStart: newRange?.start,
            newCount: newRange?.count
        )
    }

    private static func range(
        _ field: Substring,
        prefix: Character
    ) -> (start: Int, count: Int)? {
        guard field.first == prefix else { return nil }
        let components = field.dropFirst().split(
            separator: ",",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let first = components.first, let start = Int(first) else { return nil }
        let count = components.count == 2 ? Int(components[1]) : 1
        guard let count else { return nil }
        return (start, count)
    }

    private static func gitHeaderPaths(_ line: String) -> (oldPath: String?, newPath: String?) {
        let raw = line.dropFirst("diff --git ".count)
        let paths = gitTokens(raw)
        guard paths.count >= 2 else { return (nil, nil) }
        return (stripGitPrefix(paths[0]), stripGitPrefix(paths[1]))
    }

    private static func headerPath(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let raw = line.dropFirst(prefix.count)
        if raw.first == "\"" {
            return gitTokens(raw).first.flatMap(stripGitPrefix)
        }
        let path = raw.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
        return stripGitPrefix(path)
    }

    private static func renamePath(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let raw = line.dropFirst(prefix.count)
        if raw.first == "\"" {
            return gitTokens(raw).first
        }
        return raw.isEmpty ? nil : String(raw)
    }

    private static func stripGitPrefix(_ path: String) -> String? {
        guard path != "/dev/null" else { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path.isEmpty ? nil : path
    }

    private static func gitTokens<S: StringProtocol>(_ input: S) -> [String] {
        var tokens: [String] = []
        var token = ""
        var isQuoted = false
        var isEscaped = false
        var hasToken = false

        for character in input {
            if isEscaped {
                let escapedCharacter: Character =
                    switch character {
                    case "n": "\n"
                    case "r": "\r"
                    case "t": "\t"
                    default: character
                    }
                token.append(escapedCharacter)
                isEscaped = false
                hasToken = true
            } else if character == "\\" {
                isEscaped = true
                hasToken = true
            } else if character == "\"" {
                isQuoted.toggle()
                hasToken = true
            } else if character.isWhitespace, !isQuoted {
                if hasToken {
                    tokens.append(token)
                    token = ""
                    hasToken = false
                }
            } else {
                token.append(character)
                hasToken = true
            }
        }

        if isEscaped {
            token.append("\\")
        }
        if hasToken {
            tokens.append(token)
        }
        return tokens
    }
}
