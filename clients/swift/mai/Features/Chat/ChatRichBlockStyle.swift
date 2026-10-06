import Foundation

/// Presentation metrics shared by the SwiftUI and native rich-block hosts.
nonisolated enum ChatRichBlockStyle {
    static let codeHeaderHorizontalInset: CGFloat = 16
    static let codeHeaderTopInset: CGFloat = 14
    static let codeHeaderBottomInset: CGFloat = 10
    static let codeCornerRadius: CGFloat = 18
    static let codeBorderOpacity = 0.08
    static let tableToolbarHeight: CGFloat = 44

    static func codeBackgroundOpacity(isDark: Bool) -> Double {
        isDark ? 0.11 : 0.055
    }
}
