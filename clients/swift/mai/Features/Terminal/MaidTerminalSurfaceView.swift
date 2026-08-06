#if canImport(UIKit)
import GhosttyTerminal
import SwiftUI
import UIKit

/// iOS Ghostty view with the small host-specific software-keyboard corrections
/// that the package's high-level surface cannot currently inject.
final class MaidTerminalView: UITerminalView {
    weak var inputSession: InMemoryTerminalSession?
    private var focusTask: Task<Void, Never>?

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

    /// Coding terminals need committed keystrokes, not UIKit's inline
    /// composition state. The default keyboard can send ordinary Latin keys
    /// as marked text, which Ghostty renders as a malformed preedit cursor.
    /// This matches t3code's native terminal keyboard configuration.
    override var keyboardType: UIKeyboardType {
        get { .asciiCapable }
        set {}
    }

    override func insertText(_ text: String) {
        let text = TerminalInputText.normalizingSoftwareReturn(text)
        guard let inputSession else {
            super.insertText(text)
            return
        }

        // `ghostty_surface_text` is a paste API and wraps committed text in
        // bracketed-paste markers. That is correct for clipboard paste, but a
        // software-keyboard tap is ordinary terminal input; sending every
        // letter as a paste leaves shells drawing an inverted cell beside the
        // real cursor. The bundled accessory still owns clipboard paste.
        #if targetEnvironment(macCatalyst)
        super.insertText(text)
        #else
        if hasActiveStickyModifiers {
            super.insertText(text)
        } else {
            inputSession.sendInput(Data(text.utf8))
        }
        #endif
    }

    override func replace(_: UITextRange, withText text: String) {
        // Some software keyboards commit Return through UITextInput.replace
        // instead of UIKeyInput.insertText.
        insertText(text)
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        guard let markedText, !markedText.isEmpty else {
            super.setMarkedText(markedText, selectedRange: selectedRange)
            return
        }

        // iOS can route ordinary software-keyboard taps through the marked-
        // text path even for an ASCII terminal keyboard. A terminal has no
        // document for that composition to edit, so commit it immediately;
        // otherwise Ghostty correctly draws the growing preedit over the
        // cursor and the shell never receives the keystrokes.
        insertText(markedText)
    }

    override func didMoveToWindow() {
        synchronizeControllerColorScheme()
        super.didMoveToWindow()
        focusTask?.cancel()
        focusTask = nil
        guard window != nil, !isFirstResponder else { return }

        // A keyboard requested during a navigation push becomes part of the
        // horizontal transition. Wait for UIKit's actual transition completion
        // so it animates upward afterward; no guessed delay is involved.
        if let coordinator = enclosingViewController?.transitionCoordinator,
           coordinator.animate(alongsideTransition: nil, completion: { [weak self] context in
               guard !context.isCancelled else { return }
               self?.focusIfAttached()
           }) {
            return
        }

        // Views presented without a navigation transition still need one
        // layout turn before asking for their input view.
        focusTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.focusIfAttached()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        // Pre-synchronize the controller before libghostty's implementation
        // updates its TerminalViewState. Its synchronous objectWillChange
        // publication is otherwise emitted from inside a SwiftUI view update.
        synchronizeControllerColorScheme()
        super.traitCollectionDidChange(previousTraitCollection)
    }

    private func focusIfAttached() {
        focusTask = nil
        guard window != nil, !isFirstResponder else { return }
        becomeFirstResponder()
    }

    private var enclosingViewController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let viewController = next as? UIViewController {
                return viewController
            }
            responder = next
        }
        return nil
    }

    private func synchronizeControllerColorScheme() {
        let colorScheme: TerminalColorScheme = switch traitCollection.userInterfaceStyle {
        case .dark: .dark
        default: .light
        }
        controller?.setColorScheme(colorScheme)
    }
}

/// Minimal package adapter needed to construct `MaidTerminalView`. Ghostty
/// still owns rendering, hardware-key routing, and its input accessory.
struct MaidTerminalSurfaceView: UIViewRepresentable {
    @ObservedObject var context: TerminalViewState
    let inputSession: InMemoryTerminalSession
    let backgroundColor: Color

    func makeUIView(context _: Context) -> MaidTerminalView {
        let view = MaidTerminalView(frame: .zero)
        view.inputSession = inputSession
        view.delegate = context
        view.controller = context.controller
        view.configuration = context.configuration
        view.backgroundColor = UIColor(backgroundColor)
        return view
    }

    func updateUIView(_ view: MaidTerminalView, context _: Context) {
        // Controller, delegate, backend, and session are stable for this
        // representable's lifetime. Only appearance legitimately changes.
        view.backgroundColor = UIColor(backgroundColor)
    }
}
#endif
