import CoreGraphics
import Foundation

/// Who wrote a message.
nonisolated enum TranscriptRole: String, Sendable {
    case user
    case assistant
}
