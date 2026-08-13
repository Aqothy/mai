import Foundation
import SwiftUI

/// Allows ordinary web and email links while keeping custom URL schemes inert.
nonisolated enum ChatMarkdownLinkPolicy {
    static func url(for destination: String?) -> URL? {
        guard let destination = destination?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !destination.isEmpty,
            let url = URL(string: destination),
            let scheme = url.scheme?.lowercased()
        else { return nil }

        switch scheme {
        case "http", "https":
            guard url.host?.isEmpty == false else { return nil }
        case "mailto":
            guard URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.path.isEmpty == false else { return nil }
        default:
            return nil
        }
        return url
    }
}

/// Shared native-prose behavior. Attributed links use the platform's default
/// URL opening behavior and remain compatible with range selection.
struct ChatMarkdownContentStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(.primary)
            .lineSpacing(2)
            #if os(iOS) || os(macOS)
                .textSelection(.enabled)
            #endif
    }
}
