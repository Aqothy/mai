import GhosttyTerminal
import SwiftUI

/// One source of truth for the terminal theme and the background shown while
/// UIKit animates the software keyboard. The colors are Ghostty's default
/// Alabaster/Afterglow backgrounds.
enum MaidTerminalAppearance {
    private static let lightBackgroundHex = "F7F7F7"
    private static let darkBackgroundHex = "212121"

    static let theme = TerminalTheme(
        light: TerminalConfiguration.alabaster.background(lightBackgroundHex),
        dark: TerminalConfiguration.afterglow.background(darkBackgroundHex)
    )

    /// Coding tools conventionally use Option as terminal Alt/Meta rather
    /// than as an Apple keyboard-layout character modifier.
    static let terminalConfiguration = TerminalConfiguration()
        .custom("macos-option-as-alt", "true")

    static func background(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            Color(terminalHex: darkBackgroundHex)
        default:
            Color(terminalHex: lightBackgroundHex)
        }
    }
}

private extension Color {
    init(terminalHex hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
