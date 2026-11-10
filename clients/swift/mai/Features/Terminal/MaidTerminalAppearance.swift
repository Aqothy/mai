import GhosttyTerminal
import GhosttyVT
import SwiftUI

/// One source of truth for the terminal theme: Ghostty's Alabaster (light)
/// and Afterglow (dark) themes, the view configuration, and the appearance
/// the daemon answers the program's color queries with.
enum MaidTerminalAppearance {
    /// Ghostty's `Alabaster` theme file.
    private static let light = Theme(
        foreground: 0x000000, background: 0xF7F7F7, cursor: 0x007ACC, cursorText: 0xBFDBFE,
        selectionBackground: 0xBFDBFE, selectionForeground: 0x000000,
        palette: [
            0x000000, 0xAA3731, 0x448C27, 0xCB9000, 0x325CC0, 0x7A3E9D, 0x0083B2, 0xB7B7B7,
            0x777777, 0xF05050, 0x60CB00, 0xF2AF50, 0x007ACC, 0xE64CE6, 0x00AACB, 0xF7F7F7,
        ])

    /// Ghostty's `Afterglow` theme file.
    private static let dark = Theme(
        foreground: 0xD0D0D0, background: 0x212121, cursor: 0xD0D0D0, cursorText: 0x151515,
        selectionBackground: 0x303030, selectionForeground: 0xD0D0D0,
        palette: [
            0x151515, 0xAC4142, 0x7E8E50, 0xE5B567, 0x6C99BB, 0x9F4E85, 0x7DD6CF, 0xD0D0D0,
            0x505050, 0xAC4142, 0x7E8E50, 0xE5B567, 0x6C99BB, 0x9F4E85, 0x7DD6CF, 0xF5F5F5,
        ])

    private struct Theme {
        let foreground: UInt32
        let background: UInt32
        let cursor: UInt32
        let cursorText: UInt32
        let selectionBackground: UInt32
        let selectionForeground: UInt32
        let palette: [UInt32]
    }

    private static func theme(for colorScheme: ColorScheme) -> Theme {
        colorScheme == .dark ? dark : light
    }

    /// The view configuration: the daemon owns the grid, and coding tools
    /// conventionally use Option as Alt/Meta rather than as a character
    /// modifier.
    static func configuration(for colorScheme: ColorScheme, fontSize: Float) -> TerminalConfiguration {
        let theme = theme(for: colorScheme)
        var configuration = TerminalConfiguration()
        configuration.gridPolicy = .host
        configuration.optionAsAlt = .both
        configuration.font.size = Double(fontSize)
        configuration.theme.foreground = RGB(theme.foreground)
        configuration.theme.background = RGB(theme.background)
        configuration.theme.cursor = RGB(theme.cursor)
        configuration.theme.cursorText = RGB(theme.cursorText)
        configuration.theme.selectionBackground = RGB(theme.selectionBackground)
        configuration.theme.selectionForeground = RGB(theme.selectionForeground)
        configuration.theme.palette = Dictionary(
            uniqueKeysWithValues: theme.palette.enumerated().map { (UInt8($0.offset), RGB($0.element)) })
        return configuration
    }

    /// What the daemon answers OSC 10/11/4 and light/dark queries with while
    /// this view sizes the terminal.
    static func wireAppearance(for colorScheme: ColorScheme) -> TerminalAppearance {
        let theme = theme(for: colorScheme)
        return TerminalAppearance(
            background: hex(theme.background),
            colorScheme: (colorScheme == .dark ? MaidTerminalColorScheme.dark : .light).rawValue,
            foreground: hex(theme.foreground),
            palette: theme.palette.map(hex))
    }

    /// The background shown around the grid and while UIKit animates the
    /// software keyboard.
    static func background(for colorScheme: ColorScheme) -> Color {
        let value = theme(for: colorScheme).background
        return Color(
            red: Double(value >> 16 & 0xFF) / 255,
            green: Double(value >> 8 & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    private static func hex(_ value: UInt32) -> String {
        "#" + String(value, radix: 16).leftPadded(to: 6)
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        String(repeating: "0", count: max(0, length - count)) + self
    }
}
