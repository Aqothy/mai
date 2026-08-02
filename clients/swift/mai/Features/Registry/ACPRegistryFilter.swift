import Foundation

enum ACPRegistryFilter: String, CaseIterable, Identifiable {
    case all
    case installed
    case notInstalled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .installed: "Installed"
        case .notInstalled: "Not Installed"
        }
    }
}
