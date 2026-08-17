import Foundation
import Observation

/// Client-owned project and browse-location history. Paths only enter this
/// store after the daemon has returned them from filesystem browsing.
@Observable
final class ProjectFolderStore {
    private static let projectStorageKey = "project-folders"
    private static let parentStorageKey = "project-parent-folders"

    private(set) var folders: [String]
    private(set) var parentFolders: [String]

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        folders = Self.deduplicated(
            defaults?.stringArray(forKey: Self.projectStorageKey) ?? []
        )
        parentFolders = Self.deduplicated(
            defaults?.stringArray(forKey: Self.parentStorageKey) ?? []
        )
    }

    @discardableResult
    func add(_ path: String, parentPath: String? = nil) -> String? {
        guard let path = Self.normalized(path) else { return nil }
        Self.moveToFront(path, in: &folders)
        if let parentPath = Self.normalized(parentPath) {
            Self.moveToFront(parentPath, in: &parentFolders)
        }
        save()
        return path
    }

    func remove(_ path: String) {
        guard let path = Self.normalized(path) else { return }
        let previousCount = folders.count
        folders.removeAll { $0 == path }
        if folders.count != previousCount {
            save()
        }
    }

    func contains(_ path: String) -> Bool {
        guard let path = Self.normalized(path) else { return false }
        return folders.contains(path)
    }

    func rememberParentFolder(_ path: String) {
        guard let path = Self.normalized(path) else { return }
        Self.moveToFront(path, in: &parentFolders)
        save()
    }

    func removeParentFolder(_ path: String) {
        guard let path = Self.normalized(path) else { return }
        let previousCount = parentFolders.count
        parentFolders.removeAll { $0 == path }
        if parentFolders.count != previousCount {
            save()
        }
    }

    func containsParentFolder(_ path: String) -> Bool {
        guard let path = Self.normalized(path) else { return false }
        return parentFolders.contains(path)
    }

    private func save() {
        defaults?.set(folders, forKey: Self.projectStorageKey)
        defaults?.set(parentFolders, forKey: Self.parentStorageKey)
    }

    private static func moveToFront(_ path: String, in paths: inout [String]) {
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
    }

    private static func deduplicated(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.compactMap { path in
            guard let path = normalized(path), seen.insert(path).inserted else { return nil }
            return path
        }
    }

    private static func normalized(_ path: String?) -> String? {
        guard var path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else { return nil }

        while path.count > 1,
            path.hasSuffix("/") || path.hasSuffix("\\")
        {
            let characters = Array(path)
            let isWindowsDriveRoot = characters.count == 3
                && characters[1] == ":"
                && (characters[2] == "/" || characters[2] == "\\")
            if isWindowsDriveRoot { break }
            path.removeLast()
        }
        return path
    }
}
