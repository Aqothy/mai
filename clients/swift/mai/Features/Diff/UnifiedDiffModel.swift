import Foundation

nonisolated struct UnifiedDiffLine: Identifiable, Sendable, Equatable {
    /// Structural identity: hunk identity plus the line's offset inside the
    /// hunk, so appended re-parses keep existing ids stable.
    struct ID: Hashable, Sendable {
        let hunkID: UnifiedDiffHunk.ID
        let offset: Int
    }

    enum Kind: Equatable, Sendable {
        case context
        case addition
        case deletion
        case noNewline
        case unsupported

        var prefix: String {
            switch self {
            case .context:
                " "
            case .addition:
                "+"
            case .deletion:
                "-"
            case .noNewline:
                "\\"
            case .unsupported:
                "?"
            }
        }
    }

    let id: ID
    let kind: Kind
    let content: String
    let oldLineNumber: Int?
    let newLineNumber: Int?

    /// A later highlighting pass can populate this without changing parsing or
    /// the line view. Plain parsing deliberately leaves it nil.
    let attributedContent: AttributedString?
}

nonisolated struct UnifiedDiffHunk: Identifiable, Sendable, Equatable {
    /// Structural identity: file identity plus the hunk's header start lines,
    /// with an ordinal to disambiguate duplicate starts in malformed patches.
    struct ID: Hashable, Sendable {
        let fileID: UnifiedDiffFile.ID
        let oldStart: Int?
        let newStart: Int?
        let ordinal: Int
    }

    let id: ID
    let header: String
    let oldStart: Int?
    let oldCount: Int?
    let newStart: Int?
    let newCount: Int?
    let lines: [UnifiedDiffLine]
}

nonisolated struct UnifiedDiffFile: Identifiable, Sendable, Equatable {
    /// Structural identity: display path plus an ordinal disambiguating
    /// duplicate paths, so ids survive re-parses of a growing patch.
    struct ID: Hashable, Sendable {
        let path: String
        let ordinal: Int
    }

    enum Status: Equatable, Sendable {
        case modified
        case added
        case deleted
        case renamed
        case unknown

        var label: String {
            switch self {
            case .modified:
                "Modified"
            case .added:
                "Added"
            case .deleted:
                "Deleted"
            case .renamed:
                "Renamed"
            case .unknown:
                "Partial"
            }
        }
    }

    let id: ID
    let oldPath: String?
    let newPath: String?
    let status: Status
    let isBinary: Bool
    let metadataLines: [String]
    let hunks: [UnifiedDiffHunk]

    var displayPath: String {
        newPath ?? oldPath ?? "Partial diff"
    }

    var pathDescription: String {
        switch (oldPath, newPath) {
        case (let oldPath?, let newPath?) where oldPath != newPath:
            "\(oldPath) → \(newPath)"
        case (let oldPath?, nil):
            "\(oldPath) → /dev/null"
        case (nil, let newPath?):
            "/dev/null → \(newPath)"
        default:
            displayPath
        }
    }
}

// Parser and adapter builders emit placeholder ids; UnifiedDiffDocument.init
// assigns the real structural identity for everything it contains.
nonisolated extension UnifiedDiffFile.ID {
    static let placeholder = UnifiedDiffFile.ID(path: "", ordinal: 0)
}

nonisolated extension UnifiedDiffHunk.ID {
    static let placeholder = UnifiedDiffHunk.ID(
        fileID: .placeholder,
        oldStart: nil,
        newStart: nil,
        ordinal: 0
    )
}

nonisolated extension UnifiedDiffLine.ID {
    static let placeholder = UnifiedDiffLine.ID(hunkID: .placeholder, offset: 0)
}

nonisolated enum UnifiedDiffPresentationRow: Identifiable, Sendable, Equatable {
    enum ID: Hashable, Sendable {
        case file(UnifiedDiffFile.ID)
        case metadata(fileID: UnifiedDiffFile.ID, index: Int)
        case binary(UnifiedDiffFile.ID)
        case hunk(UnifiedDiffHunk.ID)
        case line(UnifiedDiffLine.ID)
    }

    case file(UnifiedDiffFile)
    case metadata(fileID: UnifiedDiffFile.ID, index: Int, text: String)
    case binary(UnifiedDiffFile)
    case hunk(fileID: UnifiedDiffFile.ID, hunk: UnifiedDiffHunk)
    case line(fileID: UnifiedDiffFile.ID, hunkID: UnifiedDiffHunk.ID, line: UnifiedDiffLine)

    var id: ID {
        switch self {
        case .file(let file):
            .file(file.id)
        case .metadata(let fileID, let index, _):
            .metadata(fileID: fileID, index: index)
        case .binary(let file):
            .binary(file.id)
        case .hunk(_, let hunk):
            .hunk(hunk.id)
        case .line(_, _, let line):
            .line(line.id)
        }
    }
}

nonisolated struct UnifiedDiffDocument: Sendable, Equatable {
    static let empty = UnifiedDiffDocument(files: [])

    let files: [UnifiedDiffFile]
    let rows: [UnifiedDiffPresentationRow]

    static func == (lhs: UnifiedDiffDocument, rhs: UnifiedDiffDocument) -> Bool {
        // rows are derived deterministically from files.
        lhs.files == rhs.files
    }

    init(files sourceFiles: [UnifiedDiffFile]) {
        // Identity is derived from structure (paths, hunk starts, offsets)
        // instead of encounter order, so re-parsing a streamed patch that only
        // grew keeps every previously assigned id stable.
        var fileOrdinals: [String: Int] = [:]

        let files = sourceFiles.map { file -> UnifiedDiffFile in
            let path = file.displayPath
            let fileOrdinal = fileOrdinals[path, default: 0]
            fileOrdinals[path] = fileOrdinal + 1
            let fileID = UnifiedDiffFile.ID(path: path, ordinal: fileOrdinal)

            // Keyed by the ordinal-0 id so duplicate hunk starts (malformed or
            // partial patches) still get unique ids within the file.
            var hunkOrdinals: [UnifiedDiffHunk.ID: Int] = [:]
            let hunks = file.hunks.map { hunk -> UnifiedDiffHunk in
                let prototype = UnifiedDiffHunk.ID(
                    fileID: fileID,
                    oldStart: hunk.oldStart,
                    newStart: hunk.newStart,
                    ordinal: 0
                )
                let hunkOrdinal = hunkOrdinals[prototype, default: 0]
                hunkOrdinals[prototype] = hunkOrdinal + 1
                let hunkID = UnifiedDiffHunk.ID(
                    fileID: fileID,
                    oldStart: hunk.oldStart,
                    newStart: hunk.newStart,
                    ordinal: hunkOrdinal
                )
                let lines = hunk.lines.enumerated().map { offset, line in
                    UnifiedDiffLine(
                        id: UnifiedDiffLine.ID(hunkID: hunkID, offset: offset),
                        kind: line.kind,
                        content: line.content,
                        oldLineNumber: line.oldLineNumber,
                        newLineNumber: line.newLineNumber,
                        attributedContent: line.attributedContent
                    )
                }
                return UnifiedDiffHunk(
                    id: hunkID,
                    header: hunk.header,
                    oldStart: hunk.oldStart,
                    oldCount: hunk.oldCount,
                    newStart: hunk.newStart,
                    newCount: hunk.newCount,
                    lines: lines
                )
            }
            return UnifiedDiffFile(
                id: fileID,
                oldPath: file.oldPath,
                newPath: file.newPath,
                status: file.status,
                isBinary: file.isBinary,
                metadataLines: file.metadataLines,
                hunks: hunks
            )
        }

        var rows: [UnifiedDiffPresentationRow] = []
        rows.reserveCapacity(
            files.reduce(0) { count, file in
                count + 1 + file.metadataLines.count
                    + file.hunks.reduce(0) { $0 + 1 + $1.lines.count }
                    + (file.isBinary ? 1 : 0)
            }
        )
        for file in files {
            rows.append(.file(file))
            for (index, metadata) in file.metadataLines.enumerated() {
                rows.append(.metadata(fileID: file.id, index: index, text: metadata))
            }
            if file.isBinary {
                rows.append(.binary(file))
                continue
            }
            for hunk in file.hunks {
                rows.append(.hunk(fileID: file.id, hunk: hunk))
                rows.append(
                    contentsOf: hunk.lines.map {
                        .line(fileID: file.id, hunkID: hunk.id, line: $0)
                    }
                )
            }
        }

        self.files = files
        self.rows = rows
    }
}
