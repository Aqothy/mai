import SwiftUI
#if os(macOS)
    import AppKit
#endif

/// The typography and spacing for native chat prose.
///
/// Keeping the scale in one place makes the renderer themeable without
/// coupling parsing to either SwiftUI or TextKit. The hierarchy intentionally
/// stays compact at chat widths, similar to the system typography used by the
/// ChatGPT iOS app.
nonisolated enum ChatMarkdownProseStyle {
    static let blockSpacing: CGFloat = 16
    static let lineSpacing: CGFloat = 2
    static let listIndent: CGFloat = 20
    static let listMarkerSpacing: CGFloat = 10
    static let listItemSpacing: CGFloat = 8
    static let quoteIndent: CGFloat = 14
    static let quoteBarWidth: CGFloat = 3

    static func headingFont(level: Int) -> Font {
        switch max(1, min(6, level)) {
        case 1:
            .title2
        case 2:
            .title3
        case 3:
            .headline
        case 4:
            .body
        case 5:
            .callout
        default:
            .subheadline
        }
    }

    #if os(iOS)
        static func headingTextStyle(level: Int) -> UIFont.TextStyle {
            switch max(1, min(6, level)) {
            case 1:
                .title2
            case 2:
                .title3
            case 3:
                .headline
            case 4:
                .body
            case 5:
                .callout
            default:
                .subheadline
            }
        }
    #elseif os(macOS)
        static func headingTextStyle(level: Int) -> NSFont.TextStyle {
            switch max(1, min(6, level)) {
            case 1:
                .title2
            case 2:
                .title3
            case 3:
                .headline
            case 4:
                .body
            case 5:
                .callout
            default:
                .subheadline
            }
        }
    #endif
}
