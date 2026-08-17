import Foundation
import Observation

@Observable
final class FolderPickerModel {
    private struct DirectorySnapshot {
        let path: String
        let parentPath: String?
        let entries: [WorkspaceDirectoryEntry]
    }

    var searchText = ""

    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let store: ThreadStore
    private let projectFolders: ProjectFolderStore
    private var snapshot: DirectorySnapshot?
    private var browseGeneration = 0

    init(store: ThreadStore, projectFolders: ProjectFolderStore) {
        self.store = store
        self.projectFolders = projectFolders
    }

    var currentPath: String? { snapshot?.path }
    var currentFolderName: String? {
        guard let currentPath else { return nil }
        let name = URL(filePath: currentPath).lastPathComponent
        return name.isEmpty ? currentPath : name
    }
    var parentPath: String? { snapshot?.parentPath }
    var parentFolders: [String] { projectFolders.parentFolders }
    var isInitialLoading: Bool { isLoading && snapshot == nil }

    var canSelectCurrentFolder: Bool {
        currentPath != nil && !isLoading
    }

    var currentFolderIsRemembered: Bool {
        currentPath.map(projectFolders.containsParentFolder) == true
    }

    var visibleEntries: [WorkspaceDirectoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let showHidden = query.hasPrefix(".")
        return (snapshot?.entries ?? []).filter { entry in
            (showHidden || !entry.name.hasPrefix("."))
                && (query.isEmpty || entry.name.localizedStandardContains(query))
        }
    }

    func loadInitialPath() async {
        guard snapshot == nil, !isLoading else { return }
        await browse(parentFolders.first)
    }

    func browse(_ path: String?) async {
        browseGeneration += 1
        let generation = browseGeneration
        isLoading = true
        errorMessage = nil

        do {
            let result = try await store.browseWorkspaceDirectories(at: path)
            try Task.checkCancellation()
            guard browseGeneration == generation else { return }
            snapshot = DirectorySnapshot(
                path: result.path,
                parentPath: result.parentPath,
                entries: result.entries
            )
            searchText = ""
            isLoading = false
        } catch is CancellationError {
            guard browseGeneration == generation else { return }
            isLoading = false
        } catch {
            guard browseGeneration == generation else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func rememberCurrentFolder() {
        guard let currentPath else { return }
        projectFolders.rememberParentFolder(currentPath)
    }

    func forgetCurrentFolder() {
        guard let currentPath else { return }
        projectFolders.removeParentFolder(currentPath)
    }
}
