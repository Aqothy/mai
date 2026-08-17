import Foundation
import SwiftUI

/// Allows ordinary web and email links while keeping custom URL schemes inert.
nonisolated enum ChatMarkdownLinkPolicy {
    static func url(for destination: String?) -> URL? {
        guard
            let destination = destination?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !destination.isEmpty,
            let url = URL(string: destination),
            let scheme = url.scheme?.lowercased()
        else { return nil }

        switch scheme {
        case "http", "https":
            guard url.host?.isEmpty == false else { return nil }
        case "mailto":
            guard
                URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false
                )?.path.isEmpty == false
            else { return nil }
        default:
            return nil
        }
        return url
    }
}

/// Shared rich-content styling. Selection is attached by the prose and code
/// leaf renderers; applying it here makes every table cell and control build
/// SwiftUI's selectable-text graph even though tables already have one copy
/// action. Attributed links use the platform's default URL opening behavior.
struct ChatMarkdownContentStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(.primary)
            .lineSpacing(2)
    }
}
