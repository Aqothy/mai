import Foundation

#if os(macOS)
    struct ChatMacScrollGeometry: Equatable {
        let isNearTop: Bool
        let isNearBottom: Bool
        let containerWidth: CGFloat
        let containerHeight: CGFloat
        let bottomInset: CGFloat
        let contentHeight: CGFloat
    }
#endif
