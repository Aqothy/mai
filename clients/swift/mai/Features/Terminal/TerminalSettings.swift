import Foundation

/// Persisted terminal presentation preferences. Only the values maiD owns
/// live here; rendering, shaping, and zoom gestures belong to the package.
@Observable
final class TerminalSettings {
    static let shared = TerminalSettings()

    static let defaultFontSize: Float = 12
    static let fontSizeRange: ClosedRange<Float> = 9...24
    private static let fontSizeStep: Float = 1
    private static let fontSizeKey = "terminal.fontSize"

    @ObservationIgnored private let defaults: UserDefaults

    var fontSize: Float {
        didSet {
            fontSize = fontSize.clamped(to: Self.fontSizeRange)
            defaults.set(Double(fontSize), forKey: Self.fontSizeKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.fontSizeKey) as? Double
        fontSize = Float(stored ?? Double(Self.defaultFontSize))
            .clamped(to: Self.fontSizeRange)
    }

    var canIncrease: Bool { fontSize < Self.fontSizeRange.upperBound }
    var canDecrease: Bool { fontSize > Self.fontSizeRange.lowerBound }

    func increaseFontSize() {
        fontSize += Self.fontSizeStep
    }

    func decreaseFontSize() {
        fontSize -= Self.fontSizeStep
    }

    func resetFontSize() {
        fontSize = Self.defaultFontSize
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
