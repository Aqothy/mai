import Foundation

#if os(macOS)
    import AppKit

    typealias ChatPlatformTextStyle = NSFont.TextStyle
    typealias ChatPlatformColor = NSColor
    typealias ChatPlatformFont = NSFont
    typealias ChatPlatformView = NSView
#else
    import UIKit

    typealias ChatPlatformTextStyle = UIFont.TextStyle
    typealias ChatPlatformColor = UIColor
    typealias ChatPlatformFont = UIFont
    typealias ChatPlatformView = UIView
#endif

/// The typography and spacing for chat prose and the hosts that decorate it.
/// The heading scale stays compact at chat widths.
nonisolated enum ChatMarkdownProseStyle {
    static let blockSpacing: CGFloat = 16
    static let lineSpacing: CGFloat = 2
    static let listIndent: CGFloat = 20
    static let listItemSpacing: CGFloat = 8
    static let quoteIndent: CGFloat = 14
    static let quoteBarWidth: CGFloat = 3

    static func headingTextStyle(level: Int) -> ChatPlatformTextStyle {
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
}
