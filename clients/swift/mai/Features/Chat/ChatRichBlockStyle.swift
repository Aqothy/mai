import Foundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Presentation metrics shared by the SwiftUI and native rich-block hosts.
nonisolated enum ChatRichBlockStyle {
    static let codeHeaderHorizontalInset: CGFloat = 16
    static let codeHeaderTopInset: CGFloat = 14
    static let codeHeaderBottomInset: CGFloat = 10
    static let codeCornerRadius: CGFloat = 18
    static let codeBorderOpacity = 0.08
    static let tableToolbarHeight: CGFloat = 44

    /// The line the language label and copy button share. The SwiftUI and
    /// native headers both take exactly this, so a code block's height is
    /// known without laying its header out.
    static var codeHeaderContentHeight: CGFloat {
        let font = ChatPlatformFont.preferredFont(forTextStyle: .callout)
        #if os(macOS)
            return ceil(font.ascender - font.descender + font.leading)
        #else
            return ceil(font.lineHeight)
        #endif
    }

    static var codeHeaderHeight: CGFloat {
        codeHeaderTopInset + codeHeaderContentHeight + codeHeaderBottomInset
    }

    static func codeBackgroundOpacity(isDark: Bool) -> Double {
        isDark ? 0.11 : 0.055
    }
}
