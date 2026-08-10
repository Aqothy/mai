enum WorkspaceFileSearchScope: Equatable {
    case thread(id: String)
    case workingDirectory(String)

    var isAvailable: Bool {
        switch self {
        case .thread(let id):
            !id.isEmpty
        case .workingDirectory(let path):
            !path.isEmpty
        }
    }

    func request(query: String, limit: Int) -> WorkspaceSearchFilesParams {
        switch self {
        case .thread(let id):
            WorkspaceSearchFilesParams(
                cwd: nil,
                limit: limit,
                query: query,
                threadID: id
            )
        case .workingDirectory(let path):
            WorkspaceSearchFilesParams(
                cwd: path,
                limit: limit,
                query: query,
                threadID: nil
            )
        }
    }
}
