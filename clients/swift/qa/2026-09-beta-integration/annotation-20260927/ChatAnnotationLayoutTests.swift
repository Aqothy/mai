#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import mai

// These checks need the real editor and software keyboard; pure model tests
// cannot establish whether the note remains visible in its presented sheet.
@Suite(.serialized)
struct ChatAnnotationLayoutTests {
    @Test @MainActor
    func longQuoteLeavesAnEditableNoteAboveTheKeyboard() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldKey = scene.windows.first(where: \.isKeyWindow)
        let model = ChatAnnotationModel()
        let quote = (1...100).map { "Quote paragraph \($0): café 👩🏽‍💻 and selected context must remain readable." }.joined(separator: "\n\n")
        model.beginComment(quote: quote, messageID: "qa-message", role: "assistant")
        model.editorDraft?.note = "This note must stay editable."
        let controller = UIHostingController(rootView: AnnotationSheetFixture(model: model))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            oldKey?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(600))
        let sheet = try #require(controller.presentedViewController)
        let keyboardGuide = sheet.view.keyboardLayoutGuide
        let editors = descendants(window).compactMap { $0 as? UITextView }
        let candidate = editors.first(where: { $0.isEditable })
        let editor = try #require(candidate)
        #expect(editor.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        let keyboard = sheet.view.convert(keyboardGuide.layoutFrame, to: window)
        let frame = editor.convert(editor.bounds, to: window)
        let available = sheet.view.convert(sheet.view.bounds, to: window)
            .intersection(CGRect(x: 0, y: 0, width: window.bounds.width, height: keyboard.minY))
        let visible = frame.intersection(available)
        let lineHeight = editor.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        print("ANNOTATION_LAYOUT system=\(UIDevice.current.systemVersion) simulator=\(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "unknown") window=\(window.bounds) keyboard=\(keyboard) editor=\(frame) visible=\(visible) lineHeight=\(lineHeight)")
        #expect(keyboard.height > window.safeAreaInsets.bottom)
        #expect(!visible.isNull && visible.height >= lineHeight * 3)
        #expect(editor.isFirstResponder)
        editor.selectedRange = NSRange(location: editor.text.utf16.count, length: 0)
        editor.insertText("\n追加 café 👩🏽‍💻")
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.editorDraft?.note == "This note must stay editable.\n追加 café 👩🏽‍💻")
        #expect(model.editorDraft?.quote == quote)
    }

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

private struct AnnotationSheetFixture: View {
    let model: ChatAnnotationModel
    @State private var presented = true

    var body: some View {
        Color.clear.sheet(isPresented: $presented) {
            ChatAnnotationEditor(model: model)
        }
    }
}
#endif
