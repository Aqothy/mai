struct WorkspaceFileMatch: Identifiable, Equatable {
    let displayName: String
    let directoryPath: String
    let relativePath: String

    var id: String { relativePath }

    init(entry: WorkspaceFileEntry) {
        displayName = entry.displayName
        relativePath = entry.relativePath

        if let separator = entry.relativePath.lastIndex(of: "/") {
            directoryPath = String(entry.relativePath[..<separator])
        } else {
            directoryPath = "."
        }
    }
}
