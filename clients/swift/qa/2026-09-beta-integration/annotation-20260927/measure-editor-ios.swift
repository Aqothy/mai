// Xcode MCP, ChatAnnotationModel.swift, iOS preview host. Verify the printed runtime.
import UIKit
import SwiftUI

try await Task { @MainActor in
    print("RUNTIME iOS \(UIDevice.current.systemVersion), simulator=\(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "unknown")")
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
        print("FAIL: no window scene")
        return
    }
    let oldKey = scene.windows.first(where: \.isKeyWindow)
    let model = ChatAnnotationModel()
    let quote = (1...100).map { "Quote paragraph \($0): café 👩🏽‍💻 and selected context must remain readable." }.joined(separator: "\n\n")
    model.beginComment(quote: quote, messageID: "qa-message", role: "assistant")
    model.editorDraft?.note = "This note must stay editable."
    let controller = UIHostingController(rootView: ChatAnnotationEditor(model: model))
    let window = UIWindow(windowScene: scene)
    window.rootViewController = controller
    let keyboardGuide = controller.view.keyboardLayoutGuide
    window.makeKeyAndVisible()
    defer { window.isHidden = true; oldKey?.makeKey() }
    try await Task.sleep(for: .milliseconds(600))
    window.layoutIfNeeded()
    func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    guard let editor = descendants(controller.view).compactMap({ $0 as? UITextView }).first(where: \.isEditable) else {
        print("FAIL: editable Comment text view not found")
        return
    }
    print("Explicit focus acquired: \(editor.becomeFirstResponder())")
    try await Task.sleep(for: .milliseconds(500))
    window.layoutIfNeeded()
    let frame = editor.convert(editor.bounds, to: window)
    let keyboard = controller.view.convert(keyboardGuide.layoutFrame, to: window)
    let visibleBottom = keyboard.height > 0 ? keyboard.minY : window.bounds.maxY - window.safeAreaInsets.bottom
    let available = CGRect(x: 0, y: window.safeAreaInsets.top, width: window.bounds.width, height: max(0, visibleBottom - window.safeAreaInsets.top))
    let visible = frame.intersection(available)
    let lineHeight = editor.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
    print("Quote characters: \(quote.count), window: \(window.bounds), keyboard guide: \(keyboard), editor: \(frame), visible: \(visible), first responder: \(editor.isFirstResponder), line height: \(lineHeight)")
    guard keyboard.height > window.safeAreaInsets.bottom else {
        print("INCOMPLETE: software keyboard not visibly occupying the window")
        return
    }
    guard !visible.isNull, visible.height >= lineHeight * 3 else {
        print("FAIL: long quote leaves fewer than three visible lines above the keyboard")
        return
    }
    editor.selectedRange = NSRange(location: editor.text.utf16.count, length: 0)
    editor.insertText("\n追加 café 👩🏽‍💻")
    try await Task.sleep(for: .milliseconds(150))
    guard model.editorDraft?.note == "This note must stay editable.\n追加 café 👩🏽‍💻" else {
        print("FAIL: native note editing did not update the draft exactly")
        return
    }
    for button in descendants(controller.view).compactMap({ $0 as? UIButton }) {
        let label = button.accessibilityLabel ?? button.title(for: .normal) ?? "unlabelled"
        print("Button: \(label), frame: \(button.convert(button.bounds, to: window)), events: \(button.allControlEvents.rawValue), enabled: \(button.isEnabled)")
    }
    print("PASS: long quote leaves an editable note above the software keyboard; native Unicode editing preserved")
}.value
