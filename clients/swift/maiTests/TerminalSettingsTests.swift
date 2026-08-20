import Foundation
import Testing

@testable import mai

@MainActor
struct TerminalSettingsTests {
    private func makeSettings() -> TerminalSettings {
        let defaults = UserDefaults(suiteName: "terminal-settings-tests-\(UUID().uuidString)")!
        return TerminalSettings(defaults: defaults)
    }

    @Test func fontSizeDefaultsAndClampsToRange() {
        let settings = makeSettings()
        #expect(settings.fontSize == TerminalSettings.defaultFontSize)

        settings.fontSize = 1000
        #expect(settings.fontSize == TerminalSettings.fontSizeRange.upperBound)
        #expect(!settings.canIncrease)

        settings.fontSize = 1
        #expect(settings.fontSize == TerminalSettings.fontSizeRange.lowerBound)
        #expect(!settings.canDecrease)
    }

    @Test func fontSizeAdjustmentsPersistAcrossInstances() {
        let suite = "terminal-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = TerminalSettings(defaults: defaults)

        settings.increaseFontSize()
        settings.increaseFontSize()
        let expected = settings.fontSize

        let reloaded = TerminalSettings(defaults: defaults)
        #expect(reloaded.fontSize == expected)

        reloaded.resetFontSize()
        #expect(reloaded.fontSize == TerminalSettings.defaultFontSize)
    }
}
