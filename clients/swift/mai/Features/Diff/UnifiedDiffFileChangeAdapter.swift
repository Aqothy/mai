nonisolated enum UnifiedDiffFileChangeAdapter {
    nonisolated static func adapt(
        _ changes: [UnifiedDiffSource.ToolChange]
    ) -> UnifiedDiffDocument {
        var files: [UnifiedDiffFile] = []
        files.reserveCapacity(changes.count)

        for change in changes {
            if let diff = nonEmpty(change.diff) {
                let parsedFiles = UnifiedDiffParser.parseFiles(diff)
                if !parsedFiles.isEmpty {
                    files.append(contentsOf: parsedFiles.map { overlay($0, with: change) })
                    continue
                }
            }
            files.append(file(from: change))
        }

        return UnifiedDiffDocument(files: files)
    }

    private static func overlay(
        _ file: UnifiedDiffFile,
        with change: UnifiedDiffSource.ToolChange
    ) -> UnifiedDiffFile {
        let paths = paths(for: change)
        let status = status(for: change)
        let oldPath: String?
        let newPath: String?

        switch status {
        case .added:
            oldPath = nil
            newPath = file.newPath ?? paths.newPath
        case .deleted:
            oldPath = file.oldPath ?? paths.oldPath
            newPath = nil
        case .renamed:
            oldPath = paths.oldPath ?? file.oldPath
            newPath = paths.newPath ?? file.newPath
        case .modified, .unknown:
            oldPath = file.oldPath ?? paths.oldPath
            newPath = file.newPath ?? paths.newPath
        }

        return UnifiedDiffFile(
            id: file.id,
            oldPath: oldPath,
            newPath: newPath,
            status: status == .unknown ? file.status : status,
            isBinary: file.isBinary,
            metadataLines: file.metadataLines,
            hunks: file.hunks
        )
    }

    private static func file(
        from change: UnifiedDiffSource.ToolChange
    ) -> UnifiedDiffFile {
        let explicitStatus = status(for: change)
        let status: UnifiedDiffFile.Status =
            if explicitStatus == .unknown {
                nonEmpty(change.movePath) == nil ? .modified : .renamed
            } else {
                explicitStatus
            }
        let paths = paths(for: change)
        let oldContent = textLines(change.oldText ?? "")
        let newContent = textLines(change.newText ?? "")

        guard !oldContent.lines.isEmpty || !newContent.lines.isEmpty else {
            return UnifiedDiffFile(
                id: .placeholder,
                oldPath: paths.oldPath,
                newPath: paths.newPath,
                status: status,
                isBinary: false,
                metadataLines: [],
                hunks: []
            )
        }

        var prefixCount = 0
        while prefixCount < oldContent.lines.count,
            prefixCount < newContent.lines.count,
            linesMatch(
                oldContent,
                oldIndex: prefixCount,
                newContent,
                newIndex: prefixCount
            )
        {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < oldContent.lines.count - prefixCount,
            suffixCount < newContent.lines.count - prefixCount,
            linesMatch(
                oldContent,
                oldIndex: oldContent.lines.count - suffixCount - 1,
                newContent,
                newIndex: newContent.lines.count - suffixCount - 1
            )
        {
            suffixCount += 1
        }

        var lines: [UnifiedDiffLine] = []
        lines.reserveCapacity(oldContent.lines.count + newContent.lines.count + 2)
        var oldLineNumber = 1
        var newLineNumber = 1

        func line(
            kind: UnifiedDiffLine.Kind,
            content: String,
            old: Int?,
            new: Int?
        ) -> UnifiedDiffLine {
            UnifiedDiffLine(
                id: .placeholder,
                kind: kind,
                content: content,
                oldLineNumber: old,
                newLineNumber: new,
                attributedContent: nil
            )
        }

        func marker() -> UnifiedDiffLine {
            line(
                kind: .noNewline,
                content: "No newline at end of file",
                old: nil,
                new: nil
            )
        }

        func shouldMarkOld(_ index: Int) -> Bool {
            !oldContent.hasFinalNewline && index == oldContent.lines.count - 1
        }

        func shouldMarkNew(_ index: Int) -> Bool {
            !newContent.hasFinalNewline && index == newContent.lines.count - 1
        }

        for index in 0..<prefixCount {
            lines.append(
                line(
                    kind: .context,
                    content: oldContent.lines[index],
                    old: oldLineNumber,
                    new: newLineNumber
                )
            )
            oldLineNumber += 1
            newLineNumber += 1
            if shouldMarkOld(index) || shouldMarkNew(index) {
                lines.append(marker())
            }
        }

        let oldMiddleEnd = oldContent.lines.count - suffixCount
        for index in prefixCount..<oldMiddleEnd {
            lines.append(
                line(
                    kind: .deletion,
                    content: oldContent.lines[index],
                    old: oldLineNumber,
                    new: nil
                )
            )
            oldLineNumber += 1
            if shouldMarkOld(index) {
                lines.append(marker())
            }
        }

        let newMiddleEnd = newContent.lines.count - suffixCount
        for index in prefixCount..<newMiddleEnd {
            lines.append(
                line(
                    kind: .addition,
                    content: newContent.lines[index],
                    old: nil,
                    new: newLineNumber
                )
            )
            newLineNumber += 1
            if shouldMarkNew(index) {
                lines.append(marker())
            }
        }

        if suffixCount > 0 {
            for offset in 0..<suffixCount {
                let oldIndex = oldContent.lines.count - suffixCount + offset
                let newIndex = newContent.lines.count - suffixCount + offset
                lines.append(
                    line(
                        kind: .context,
                        content: oldContent.lines[oldIndex],
                        old: oldLineNumber,
                        new: newLineNumber
                    )
                )
                oldLineNumber += 1
                newLineNumber += 1
                if shouldMarkOld(oldIndex) || shouldMarkNew(newIndex) {
                    lines.append(marker())
                }
            }
        }

        let oldStart = oldContent.lines.isEmpty ? 0 : 1
        let newStart = newContent.lines.isEmpty ? 0 : 1
        let header =
            "@@ -\(oldStart),\(oldContent.lines.count) "
            + "+\(newStart),\(newContent.lines.count) @@"
        let hunk = UnifiedDiffHunk(
            id: .placeholder,
            header: header,
            oldStart: oldStart,
            oldCount: oldContent.lines.count,
            newStart: newStart,
            newCount: newContent.lines.count,
            lines: lines
        )
        return UnifiedDiffFile(
            id: .placeholder,
            oldPath: paths.oldPath,
            newPath: paths.newPath,
            status: status,
            isBinary: false,
            metadataLines: [],
            hunks: [hunk]
        )
    }

    private static func status(
        for change: UnifiedDiffSource.ToolChange
    ) -> UnifiedDiffFile.Status {
        switch change.kind.flatMap(MaidFileChangeKind.init(rawValue:)) {
        case .add:
            .added
        case .delete:
            .deleted
        case .move:
            .renamed
        case .update:
            .modified
        case nil:
            .unknown
        }
    }

    private static func linesMatch(
        _ oldContent: (lines: [String], hasFinalNewline: Bool),
        oldIndex: Int,
        _ newContent: (lines: [String], hasFinalNewline: Bool),
        newIndex: Int
    ) -> Bool {
        guard oldContent.lines[oldIndex] == newContent.lines[newIndex] else {
            return false
        }
        let bothAreFinalLines =
            oldIndex == oldContent.lines.count - 1
            && newIndex == newContent.lines.count - 1
        return !bothAreFinalLines
            || oldContent.hasFinalNewline == newContent.hasFinalNewline
    }

    private static func paths(
        for change: UnifiedDiffSource.ToolChange
    ) -> (oldPath: String?, newPath: String?) {
        let path = nonEmpty(change.path)
        switch change.kind.flatMap(MaidFileChangeKind.init(rawValue:)) {
        case .add:
            return (nil, path)
        case .delete:
            return (path, nil)
        case .move:
            return (path, nonEmpty(change.movePath) ?? path)
        case .update, nil:
            return (path, nonEmpty(change.movePath) ?? path)
        }
    }

    private static func textLines(
        _ text: String
    ) -> (lines: [String], hasFinalNewline: Bool) {
        guard !text.isEmpty else { return ([], true) }
        let normalized =
            if text.contains("\r") {
                text.replacing("\r\n", with: "\n").replacing("\r", with: "\n")
            } else {
                text
            }
        let hasFinalNewline = normalized.hasSuffix("\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if hasFinalNewline {
            lines.removeLast()
        }
        return (lines, hasFinalNewline)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
