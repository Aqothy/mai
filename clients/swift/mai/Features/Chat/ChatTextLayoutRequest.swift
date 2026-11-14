import SwiftUI

nonisolated struct ChatTextLayoutRequest: Sendable {
    let id: String
    let content: ChatTextContent
    let width: CGFloat
}
