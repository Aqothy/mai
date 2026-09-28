// Xcode MCP, ChatAnnotationModel.swift, My Mac. Measures real hosted controls.
import AppKit
import SwiftUI

try await Task { @MainActor in
    let model = ChatAnnotationModel()
    let quote = (1...100).map { "Quote paragraph \($0): café 👩🏽‍💻 and selected context must remain readable." }.joined(separator: "\n\n")
    model.beginComment(quote: quote, messageID: "qa-message", role: "assistant")
    model.editorDraft?.note = "This note must stay editable."
    let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 500, height: 500),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: ChatAnnotationEditor(model: model))
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(300))
    host.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let editors = descendants(host).compactMap { $0 as? NSTextView }.filter(\.isEditable)
    guard let editor = editors.first, let scroll = editor.enclosingScrollView else {
        print("FAIL: editable Comment text view not found")
        return
    }
    let editorFrame = scroll.convert(scroll.bounds, to: host)
    let viewport = editorFrame.intersection(host.bounds)
    let lineHeight = editor.layoutManager?.defaultLineHeight(for: editor.font ?? NSFont.preferredFont(forTextStyle: .body)) ?? 17
    print("Quote characters: \(quote.count), host: \(host.bounds), editor: \(editorFrame), visible: \(viewport), line height: \(lineHeight)")
    guard !viewport.isNull, viewport.height >= lineHeight * 3 else {
        print("FAIL: long quote leaves fewer than three visible lines for the note")
        return
    }
    print("PASS: long quote leaves an editable note viewport")
}.value
