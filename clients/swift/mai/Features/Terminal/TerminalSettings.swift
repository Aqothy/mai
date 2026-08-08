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

    // Clamping lives in the computed setter rather than a didSet: with
    // @Observable, reassigning a tracked property inside its own didSet
    // re-enters the synthesized setter and overflows the stack.
    private var storedFontSize: Float

    var fontSize: Float {
        get { storedFontSize }
        set {
            let clamped = newValue.clamped(to: Self.fontSizeRange)
            storedFontSize = clamped
            defaults.set(Double(clamped), forKey: Self.fontSizeKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.fontSizeKey) as? Double
        storedFontSize = Float(stored ?? Double(Self.defaultFontSize))
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
