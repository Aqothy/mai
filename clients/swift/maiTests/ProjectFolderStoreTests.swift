import Foundation
import Testing

@testable import mai

@MainActor
struct ProjectFolderStoreTests {
    @Test
    func addsDeduplicatesAndPersistsFolders() throws {
        let suiteName = "ProjectFolderStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProjectFolderStore(defaults: defaults)
        store.add(" /projects/one/ ", parentPath: " /projects/ ")
        store.add("/projects/two")
        store.add("/projects/one")

        #expect(store.folders == ["/projects/one", "/projects/two"])
        #expect(store.parentFolders == ["/projects"])
        let restored = ProjectFolderStore(defaults: defaults)
        #expect(restored.folders == store.folders)
        #expect(restored.parentFolders == store.parentFolders)
    }

    @Test
    func remembersAndForgetsParentFolders() {
        let store = ProjectFolderStore(defaults: nil)
        store.rememberParentFolder("/projects/personal")
        store.rememberParentFolder("/projects/work")
        store.rememberParentFolder("/projects/personal")

        #expect(store.parentFolders == ["/projects/personal", "/projects/work"])
        store.removeParentFolder("/projects/personal")
        #expect(store.parentFolders == ["/projects/work"])
    }

    @Test
    func explicitFoldersCreateEmptyWorkspaceSections() {
        let groups = WorkspaceListGroups(
            items: [],
            projectDirectories: ["/projects/new-app"]
        )

        #expect(groups.projects.map(\.id) == ["/projects/new-app"])
        #expect(groups.projects.first?.items.isEmpty == true)
    }
}
