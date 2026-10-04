#if os(iOS)
    import SwiftUI
    import Testing
    import UIKit

    @testable import mai

    /// iOS 18 SwiftUI traps when a text field applies a selection whose indices
    /// belong to text it no longer shows. An accepted send, the draft-to-chat
    /// transition and accessibility edits all replace the composer text outside
    /// the editor's own selection updates.
    @MainActor
    struct PromptComposerSelectionTests {
        @Observable
        final class Draft {
            var text = ""
        }

        struct Host: View {
            @Bindable var draft: Draft

            var body: some View {
                PromptComposer(
                    text: $draft.text,
                    isEnabled: true,
                    focusID: "draft",
                    canSend: true,
                    isSending: false,
                    submitLabel: "Send",
                    send: {}
                ) {
                    EmptyView()
                } trailingControls: {
                    EmptyView()
                }
            }
        }

        @Test
        func replacingTypedTextKeepsTheEditorSelectionValid() async throws {
            for replacement in ["", "short", "雪"] {
                try await replaceTypedText(with: replacement)
            }
        }

        private func replaceTypedText(with replacement: String) async throws {
            let draft = Draft()
            let scene = try #require(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            )
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
            let controller = UIHostingController(rootView: Host(draft: draft))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutIfNeeded()

            let textView = try #require(Self.textView(in: controller.view))
            #expect(textView.becomeFirstResponder())
            // Typing through UIKit leaves SwiftUI's selection at the end of it.
            textView.insertText("Prompt café 🧪 " + String(repeating: "a", count: 52))
            try await Task.sleep(for: .milliseconds(300))
            #expect(draft.text.utf16.count > 60)

            draft.text = replacement
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutIfNeeded()
            #expect(textView.text == replacement)
        }

        private static func textView(in view: UIView) -> UITextView? {
            if let textView = view as? UITextView { return textView }
            for subview in view.subviews {
                if let found = textView(in: subview) { return found }
            }
            return nil
        }
    }
#endif
