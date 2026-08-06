#if canImport(UIKit)
import GhosttyTerminal
import SwiftUI
import UIKit

/// Ghostty surface with the two iOS text-input corrections that cannot be
/// configured through the package: committed software-keyboard input is a
/// keystroke (not a paste), and UIKit's redundant caret stays hidden.
final class MaidTerminalView: UITerminalView {
    weak var inputSession: InMemoryTerminalSession?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Ghostty renders the terminal cursor; UIKit's insertion caret would
        // otherwise be drawn over the same input view as a second cursor.
        tintColor = .clear
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        // Preserve the cursor location as an anchor for the input system, but
        // do not give UIKit a terminal-cell-sized caret to draw. Ghostty owns
        // the visible cursor.
        var rect = super.caretRect(for: position)
        rect.size.width = 0
        return rect
    }

    /// Inline predictions are not useful in a terminal and UIKit represents
    /// them as marked text. Letting Ghostty render that preedit can make a
    /// one-cell block cursor appear to stretch across the prediction.
    var inlinePredictionType: UITextInlinePredictionType {
        get { .no }
        set {}
    }

    override func insertText(_ text: String) {
        let text = TerminalInputText.normalizingSoftwareReturn(text)
        guard let inputSession else {
            super.insertText(text)
            return
        }

        #if targetEnvironment(macCatalyst)
        super.insertText(text)
        #else
        // Ghostty must keep ownership of real IME composition and sticky
        // modifiers. Plain committed text is terminal input, while
        // `ghostty_surface_text` uses paste semantics that can leave a wide
        // preedit-looking cursor on iOS.
        if markedTextRange != nil || hasActiveStickyModifiers {
            super.insertText(text)
        } else {
            inputSession.sendInput(Data(text.utf8))
        }
        #endif
    }

    override func replace(_: UITextRange, withText text: String) {
        // Some software keyboards commit Return through UITextInput.replace.
        insertText(text)
    }
}

/// Minimal package adapter for the iOS-specific text-input corrections.
/// Ghostty still owns rendering, focus, gestures, IME, and ongoing sizing.
struct MaidTerminalSurfaceView: UIViewRepresentable {
    @ObservedObject var context: TerminalViewState
    let inputSession: InMemoryTerminalSession

    func makeUIView(context _: Context) -> MaidTerminalView {
        let view = MaidTerminalView(frame: .zero)
        view.inputSession = inputSession
        view.delegate = context
        view.controller = context.controller
        view.configuration = context.configuration
        return view
    }

    func updateUIView(_ view: MaidTerminalView, context _: Context) {
        view.inputSession = inputSession
        view.delegate = context
        view.controller = context.controller
        view.configuration = context.configuration
    }
}
#endif
