import Foundation
import Observation

/// Browses the daemon's folders. Pinned locations are this device's
/// shortcuts into the daemon's filesystem, so they stay on the device.
@Observable
final class FolderPickerModel {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    private struct DirectorySnapshot {
        let path: String
        let parentPath: String?
        let entries: [WorkspaceDirectoryEntry]
    }

    private static let pinnedStorageKey = "project-parent-folders"

    var searchText = ""

    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// Pinned locations, most recently used first.
    private(set) var parentFolders: [String]

    private let store: ThreadStore
    private var snapshot: DirectorySnapshot?
    private var browseGeneration = 0

    init(store: ThreadStore) {
        self.store = store
        parentFolders = UserDefaults.standard.stringArray(forKey: Self.pinnedStorageKey) ?? []
    }

    var currentPath: String? { snapshot?.path }
    var currentFolderName: String? {
        guard let currentPath else { return nil }
        let name = URL(filePath: currentPath).lastPathComponent
        return name.isEmpty ? currentPath : name
    }
    var parentPath: String? { snapshot?.parentPath }
    var isInitialLoading: Bool { isLoading && snapshot == nil }

    var canSelectCurrentFolder: Bool {
        currentPath != nil && !isLoading
    }

    var currentFolderIsRemembered: Bool {
        currentPath.map(parentFolders.contains) == true
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
        pin(currentPath)
    }

    func forgetCurrentFolder() {
        guard let currentPath else { return }
        parentFolders.removeAll { $0 == currentPath }
        save()
    }

    /// The chosen folder. Its parent is pinned first, so the next browse
    /// starts beside it.
    func selectCurrentFolder() -> String? {
        guard let currentPath else { return nil }
        if let parentPath {
            pin(parentPath)
        }
        return currentPath
    }

    private func pin(_ path: String) {
        parentFolders.removeAll { $0 == path }
        parentFolders.insert(path, at: 0)
        save()
    }

    private func save() {
        UserDefaults.standard.set(parentFolders, forKey: Self.pinnedStorageKey)
    }
}
