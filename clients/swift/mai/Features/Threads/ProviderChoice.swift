import Foundation

struct ProviderChoice: Identifiable, Equatable {
    let id: String
    let name: String
    /// Where the provider runtime comes from. Several instances can share a
    /// display name, such as the built-in Codex and Codex ACP agents.
    let kind: String
    /// `name`, qualified with `kind` only when another provider shares it.
    var title: String

    init(id: String, name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
        title = name
    }
}
