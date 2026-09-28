// Run through Xcode MCP in PromptComposer.swift on My Mac.
import AppKit
import Observation
import SwiftUI

@MainActor final class ComposerKeyboardQAState {
    var text = "/"
    var changeText: ((String) -> Void)?
    var changeFocus: ((String?) -> Void)?
    var sendCount = 0
    var changeSendState: ((Bool, Bool, Bool) -> Void)?
    let completion = PromptCompletionModel(store: ThreadStore(), scope: .workingDirectory("/qa"))
    let commands = [
        SlashCommand(description: "Inspect changes", hasInput: false, inputHint: nil, name: "review"),
        SlashCommand(description: "Choose a model", hasInput: true, inputHint: "model name", name: "model")
    ]
}

@MainActor struct ComposerKeyboardQAView: View {
    let state: ComposerKeyboardQAState
    @State private var text = "/"
    @State private var allowsSend = true
    @State private var sending = false
    @State private var stopping = false
    @State private var focusID: String? = "qa-draft"
    var body: some View {
        VStack {
            if state.completion.isPresented {
                PromptCompletionView(model: state.completion) { match in
                    if let edit = state.completion.edit(selecting: match, in: text) {
                        text = edit.text
                    }
                }
            }
            PromptComposer(text: $text, isEnabled: true, focusID: focusID,
                           canSend: allowsSend && !text.isEmpty, isSending: sending, isStopping: stopping,
                           promptCompletion: state.completion, commands: state.commands,
                           submitLabel: "Send", send: { state.sendCount += 1 },
                           leadingControls: { EmptyView() }, trailingControls: { EmptyView() })
        }
        .frame(width: 700, height: 320)
        .onAppear {
            state.changeText = { text = $0 }
            state.changeSendState = { allowsSend = $0; sending = $1; stopping = $2 }
            state.changeFocus = { focusID = $0 }
        }
        .onChange(of: text, initial: true) { _, value in state.text = value }
    }
}

try await Task { @MainActor in
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { print("FAIL: \(message)"); throw NSError(domain: "ComposerKeyboardQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let state = ComposerKeyboardQAState()
    let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 700, height: 320),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "mai isolated composer QA"
    window.contentView = NSHostingView(rootView: ComposerKeyboardQAView(state: state))
    defer { window.close() }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    try await Task.sleep(for: .milliseconds(500))
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let views = window.contentView.map(descendants) ?? []
    print("Window key: \(window.isKeyWindow), native controls: \(views.filter { $0 is NSTextView || $0 is NSTextField }.map { String(describing: type(of: $0)) })")
    if let editor = views.compactMap({ $0 as? NSTextView }).first(where: \.isEditable) {
        print("Assign editor responder: \(window.makeFirstResponder(editor))")
    } else if let field = views.compactMap({ $0 as? NSTextField }).first(where: \.isEditable) {
        print("Assign field responder: \(window.makeFirstResponder(field))")
    }
    try await Task.sleep(for: .milliseconds(100))
    if let editor = window.firstResponder as? NSTextView {
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    }
    try await Task.sleep(for: .milliseconds(100))
    print("Initial responder: \(String(describing: window.firstResponder)), selection: \(state.completion.selectedMatchID ?? "none")")
    func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false) throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: code) else {
            throw NSError(domain: "ComposerKeyboardQA", code: 2)
        }
        window.sendEvent(event)
    }
    try require(state.completion.selectedMatch?.insertionValue == "review", "Initial completion not selected")
    try key(125, "\u{F701}")
    try await Task.sleep(for: .milliseconds(100))
    print("After Down: \(state.completion.selectedMatchID ?? "none"), text: \(state.text.debugDescription)")
    try require(state.completion.selectedMatch?.insertionValue == "model", "Down did not select next completion")
    try key(126, "\u{F700}")
    try await Task.sleep(for: .milliseconds(100))
    try require(state.completion.selectedMatch?.insertionValue == "review", "Up did not select previous completion")
    try key(36, "\r")
    try await Task.sleep(for: .milliseconds(150))
    print("After Return: text=\(state.text.debugDescription), presented=\(state.completion.isPresented), sends=\(state.sendCount), responder=\(String(describing: window.firstResponder))")
    try require(state.text == "/review" && !state.completion.isPresented && state.sendCount == 0, "Return did not insert only the selected completion")
    func replaceEditorText(_ value: String) throws {
        guard let editor = window.firstResponder as? NSTextView else {
            throw NSError(domain: "ComposerKeyboardQA", code: 3)
        }
        editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }
    try replaceEditorText("/m")
    try await Task.sleep(for: .milliseconds(150))
    try require(state.completion.selectedMatch?.insertionValue == "model", "Native typing did not filter commands")
    try key(48, "\t")
    try await Task.sleep(for: .milliseconds(150))
    try require(state.text == "/model " && !state.completion.isPresented, "Tab did not insert the selected command and separator")
    try replaceEditorText("/")
    try await Task.sleep(for: .milliseconds(150))
    try key(53, "\u{1B}")
    try await Task.sleep(for: .milliseconds(150))
    try require(state.text == "/" && !state.completion.isPresented, "Escape did not dismiss without editing")
    try replaceEditorText("café 👩🏽‍💻\n第二行")
    try await Task.sleep(for: .milliseconds(150))
    try require(state.text == "café 👩🏽‍💻\n第二行", "Native multiline Unicode replacement was changed")
    try key(36, "\r")
    try await Task.sleep(for: .milliseconds(100))
    try require(state.sendCount == 1, "Plain Return did not send exactly once")
    try key(36, "\r", repeating: true)
    try await Task.sleep(for: .milliseconds(100))
    try require(state.sendCount == 1, "Held Return repeated Send")
    for flags in [(false, false, false), (true, true, false), (true, false, true)] {
        state.changeSendState?(flags.0, flags.1, flags.2)
        try await Task.sleep(for: .milliseconds(100))
        try key(36, "\r")
        try await Task.sleep(for: .milliseconds(100))
        try require(state.sendCount == 1, "Unavailable, sending or stopping composer dispatched again")
    }
    state.changeSendState?(true, false, false)
    try await Task.sleep(for: .milliseconds(100))
    try key(36, "\r")
    try await Task.sleep(for: .milliseconds(100))
    try require(state.sendCount == 2, "Composer did not resume sending after becoming available")
    try key(36, "\r", modifiers: .capsLock)
    try await Task.sleep(for: .milliseconds(100))
    try require(state.sendCount == 3, "Caps Lock prevented Enter from sending")
    state.changeFocus?(nil)
    try await Task.sleep(for: .milliseconds(150))
    try require(!(window.firstResponder is NSTextView), "Draft-to-chat focus was not released")
    print("PASS: hosted composer Down/Up/Return/Tab/Escape, native Unicode replacement, draft-to-chat focus release, Enter sends once, repeat/unavailable/sending/stopping do not dispatch, sending resumes, Caps Lock does not block Enter")
}.value
