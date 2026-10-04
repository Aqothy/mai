#if os(macOS)
import AppKit
import Testing
@testable import mai

struct ChatNativeClipboardTests {
    @Test @MainActor
    func richCopyActionsAndSelectionStayCurrentAfterReuse() async throws {
        let clipboard = NSPasteboard.general
        let previous = try (clipboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                // Without a full backup, leave the user's clipboard unchanged.
                let data = try #require(item.data(forType: type))
                copy.setData(data, forType: type)
            }
            return copy
        }
        var ownedClipboardChange: Int?
        defer {
            if ownedClipboardChange == clipboard.changeCount {
                clipboard.clearContents()
                if !previous.isEmpty { clipboard.writeObjects(previous) }
            }
        }
        let layouts = ChatTextLayoutStore()
        let annotations = ChatAnnotationModel()
        let host = ChatNativePreparedRow(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
        @MainActor func render(_ content: ChatNativePreparedRow.Content, id: String, theme: ChatCodeHighlightTheme = .light) {
            host.update(.init(id: id, content: content, top: 0, bottom: 0), width: 360, store: layouts, theme: theme,
                        annotationContext: .init(messageID: id, role: "assistant", model: annotations))
            host.layoutSubtreeIfNeeded()
        }
        @MainActor func copyButton(_ label: String, expecting text: String) throws -> NSButton {
            let button = try #require(host.subviews.compactMap { $0 as? NSButton }.first { !$0.isHidden })
            try #require(button.accessibilityLabel() == label, "Incorrect copy accessibility label")
            button.performClick(nil)
            ownedClipboardChange = clipboard.changeCount
            try #require(clipboard.string(forType: .string) == text, "Actual copy action returned stale or changed content")
            try #require(button.accessibilityLabel() == "Copied", "Copy feedback absent")
            return button
        }
        render(.prose("Select **café 👩🏽‍💻** without Markdown punctuation."), id: "prose")
        let prose = try #require(host.subviews.compactMap { $0 as? ChatSelectableTextHostView }.first)
        let text = try #require(prose.subviews.compactMap { $0 as? ChatAnnotationTextView }.first)
        let selected = "café 👩🏽‍💻"
        let range = (text.string as NSString).range(of: selected)
        try #require(range.location != NSNotFound, "Rendered Unicode selection absent")
        text.setSelectedRange(range)
        text.copy(nil)
        ownedClipboardChange = clipboard.changeCount
        try #require(clipboard.string(forType: .string) == selected, "Prose copy differs from selection")
        let menu = NSMenu()
        text.appendComment(to: menu)
        let oldMenu = try #require(menu.items.last)

        let firstCode = "let first = \"café 👩🏽‍💻\"\n" + String(repeating: "// long line αβ ", count: 30)
        render(.code(.init(code: firstCode, language: "swift", kind: .fenced)), id: "code-first")
        _ = try copyButton("Copy code", expecting: firstCode)
        let code = try #require(host.subviews.compactMap { $0 as? ChatMacCodeBlockHostView }.first)
        let codeText = try #require(code.documentView as? ChatAnnotationTextView)
        code.contentView.scroll(to: NSPoint(x: 100, y: 0))
        try #require(code.contentView.bounds.minX > 0, "Wide code did not scroll horizontally")
        codeText.setSelectedRange(NSRange(location: 0, length: 3))
        text.comment(oldMenu)
        try #require(annotations.editorDraft == nil, "Detached prose menu created a comment")

        let table = ChatMarkdownTable(alignments: [.leading, .center, .trailing],
                                     header: [AttributedString("Name"), AttributedString("Quote"), AttributedString("Value")],
                                     rows: [[AttributedString("café"), AttributedString(String(repeating: "Wide 👩🏽‍💻 ", count: 20)), AttributedString("保持")]])
        render(.table(table), id: "table")
        let tableCopy = try copyButton("Copy table", expecting: table.tabSeparatedText)
        let tableHost = try #require(host.subviews.compactMap { $0 as? ChatMacTableHostView }.first)
        tableHost.contentView.scroll(to: NSPoint(x: 90, y: 0))
        try #require(tableHost.contentView.bounds.minX > 0, "Wide table did not scroll horizontally")
        try #require(host.accessibilityValue() as? String == table.tabSeparatedText, "Table accessibility content differs")
        try await Task.sleep(for: .milliseconds(1700))
        try #require(tableCopy.accessibilityLabel() == "Copy table", "Old feedback task overwrote reused button")

        let secondCode = ChatMarkdownCodeBlock(code: "let second = 42 // 保持", language: "swift", kind: .fenced)
        for theme in [ChatCodeHighlightTheme.dark, .light] {
            await layouts.prepareCodeBlocks(requests: [.init(id: "code-second", block: secondCode, theme: theme)])
            render(.code(secondCode), id: "code-second", theme: theme)
            try #require(host.subviews.contains { $0 === code }, "Code body was not reused")
            try #require(codeText.string == secondCode.code, "Reused code retained old text")
            try #require(codeText.selectedRange().length == 0 && code.contentView.bounds.minX == 0, "Code selection or horizontal offset leaked")
            let expected = NSMutableAttributedString(attributedString:
                layouts.codeLayout(id: "code-second", block: secondCode, theme: theme).layout.attributedString)
            // NSTextStorage substitutes a CJK font for 保持. Apply the same
            // documented font fixing before comparing every rendered attribute.
            expected.fixFontAttribute(in: NSRange(location: 0, length: expected.length))
            try #require(codeText.attributedString().isEqual(to: expected), "Rendered syntax attributes differ from the prepared theme")
            _ = try copyButton("Copy code", expecting: secondCode.code)
        }
        render(.prose("Fresh unrelated row"), id: "prose-new")
        try #require(host.subviews.contains { $0 === prose }, "Prose body was not reused")
        try #require(text.string == "Fresh unrelated row" && text.selectedRange().length == 0, "Prose selection/content leaked")
        try #require(host.accessibilityValue() == nil, "Old table accessibility value leaked")
        try #require(host.subviews.compactMap { $0 as? NSButton }.allSatisfy { $0.isHidden }, "Old copy button remained visible")
        try await Task.sleep(for: .milliseconds(1700))
        try #require(host.accessibilityValue() == nil, "Delayed feedback restored stale accessibility content")
    }
}
#endif
