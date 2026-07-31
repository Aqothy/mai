import SwiftUI

/// Small shared helpers for the thread list UI.

enum ProviderDriverLabel {
    /// Human-readable name for a driver identifier: "claude-code" becomes
    /// "Claude Code", and short identifiers like "acp" become "ACP".
    static func displayName(forDriver driver: String) -> String {
        let words = driver
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map(String.init)
        if words.count == 1, let word = words.first, word.count <= 4 {
            return word.uppercased()
        }
        return words.map(\.capitalized).joined(separator: " ")
    }
}

/// Glass capsule on OS versions that support it, material capsule otherwise.
struct StatusCapsuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: .capsule)
        }
    }
}
