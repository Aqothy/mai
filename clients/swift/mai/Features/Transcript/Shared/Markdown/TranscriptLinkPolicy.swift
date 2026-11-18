import CoreGraphics
import Foundation

/// Opens ordinary web and email links and keeps every other scheme inert: a
/// model's output must not launch apps or local URLs.
nonisolated enum TranscriptLinkPolicy {
    static func url(for destination: String?) -> URL? {
        guard let destination = destination?.trimmingCharacters(in: .whitespacesAndNewlines),
            !destination.isEmpty, let url = URL(string: destination),
            let scheme = url.scheme?.lowercased()
        else { return nil }
        switch scheme {
        case "http", "https":
            return url.host?.isEmpty == false ? url : nil
        case "mailto":
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
            return path.isEmpty ? nil : url
        default:
            return nil
        }
    }
}
