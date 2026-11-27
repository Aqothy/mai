import Foundation

/// Opens ordinary web and email links and keeps every other scheme inert: a
/// model's output must not launch apps or local URLs.
nonisolated enum TranscriptLinkPolicy {
    static func url(for destination: String?) -> URL? {
        guard let destination else { return nil }
        // Reject relative paths and other schemes before allocating a `URL`.
        let utf8 = destination.utf8
        guard let colon = utf8.firstIndex(of: UInt8(ascii: ":")),
            (4...6).contains(utf8.distance(from: utf8.startIndex, to: colon))
        else { return nil }
        guard let url = URL(string: percentEncoded(destination)), let scheme = url.scheme?.lowercased() else {
            return nil
        }
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

    /// CommonMark's destination normalization, as `@pierre/words` writes an
    /// `href`: bytes outside ``A-Za-z0-9 !#$%&'()*+,-./:;=?@_~`` become `%XX`,
    /// so a destination with spaces, quotes or non-ASCII text is still a URL.
    private static func percentEncoded(_ destination: String) -> String {
        guard destination.utf8.contains(where: { !isSafe($0) }) else { return destination }
        var out: [UInt8] = []
        out.reserveCapacity(destination.utf8.count &* 3)
        let hex = Array("0123456789ABCDEF".utf8)
        for byte in destination.utf8 {
            if isSafe(byte) {
                out.append(byte)
            } else {
                out.append(UInt8(ascii: "%"))
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 15)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    @inline(__always)
    private static func isSafe(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "#")...UInt8(ascii: ";"), UInt8(ascii: "!"), UInt8(ascii: "="), UInt8(ascii: "?"),
            UInt8(ascii: "@"), UInt8(ascii: "_"), UInt8(ascii: "~"):
            true
        default:
            false
        }
    }
}
