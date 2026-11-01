import Foundation

/// JSON dates from the daemon use RFC 3339 with optional fractional seconds.
/// Foundation's built-in .iso8601 decoding strategy rejects fractions on
/// older supported runtimes, even when the app is built with a newer SDK.
nonisolated enum WireJSON {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let source = try container.decode(String.self)
            guard let date = parseDate(source) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an RFC 3339 timestamp with optional fractional seconds."
                )
            }
            return date
        }
        return decoder
    }

    static func parseDate(_ source: String) -> Date? {
        // On older runtimes, each style requires its exact fraction form.
        (try? Date(source, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(source, strategy: .iso8601))
    }
}
