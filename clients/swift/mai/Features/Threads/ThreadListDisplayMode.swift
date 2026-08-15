import Foundation

/// How the Threads list arranges its rows: a flat recency list with
/// two-line rows, or grouped by project with compact one-line rows (the
/// section header carries the project context).
enum ThreadListDisplayMode: String, CaseIterable, Identifiable {
    case recent
    case byProject

    static let appStorageKey = "threadListDisplayMode"

    var id: Self { self }

    var title: String {
        switch self {
        case .recent: "Recent"
        case .byProject: "By Project"
        }
    }

    var systemImage: String {
        switch self {
        case .recent: "clock"
        case .byProject: "folder"
        }
    }
}

/// The set of collapsed project sections in the "By Project" mode, stored
/// as one string so @AppStorage can persist it across launches and share
/// it between the platform layouts. Sections default to expanded.
struct CollapsedProjectDirectories: RawRepresentable, Equatable {
    static let appStorageKey = "collapsedProjectDirectories"

    var values: Set<String>

    init() {
        values = []
    }

    // Paths cannot contain a newline, so it is a safe separator.
    init(rawValue: String) {
        values = Set(rawValue.split(separator: "\n").map(String.init))
    }

    var rawValue: String {
        values.sorted().joined(separator: "\n")
    }

    func isExpanded(_ projectDirectory: String) -> Bool {
        !values.contains(projectDirectory)
    }

    mutating func setExpanded(_ expanded: Bool, for projectDirectory: String) {
        if expanded {
            values.remove(projectDirectory)
        } else {
            values.insert(projectDirectory)
        }
    }
}
