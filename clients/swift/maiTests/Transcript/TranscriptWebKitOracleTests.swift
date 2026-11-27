#if os(macOS)
    import AppKit
    import CoreGraphics
    import Foundation
    import Testing
    import WebKit

    @testable import mai

    /// Differential oracle against live WebKit (`WKWebView`, Safari's engine):
    /// compares our Markdown text/block structure, word/paragraph selection
    /// ranges, and RTL `dir="auto"` alignment directly against a real browser.
    @Suite(.serialized)
    struct TranscriptWebKitOracleTests {
        private final class NavigationWaiter: NSObject, WKNavigationDelegate {
            var continuation: CheckedContinuation<Void, Never>?

            private func finish() {
                continuation?.resume()
                continuation = nil
            }

            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) { finish() }
            func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) { finish() }
            func webView(
                _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error
            ) { finish() }
            func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish() }
        }

        /// Reused across oracle tests so the suite boots one WebContent XPC
        /// process instead of spawning four separate ones (~5× faster).
        private static let sharedWebView: (webView: WKWebView, waiter: NavigationWaiter) = {
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
            let waiter = NavigationWaiter()
            webView.navigationDelegate = waiter
            return (webView, waiter)
        }()

        private func makeWebView(width: CGFloat = 600, height: CGFloat = 800) -> (WKWebView, NavigationWaiter) {
            let pair = Self.sharedWebView
            let frame = CGRect(x: 0, y: 0, width: width, height: height)
            if pair.webView.frame != frame { pair.webView.frame = frame }
            return pair
        }

        private func load(_ html: String, in webView: WKWebView, waiter: NavigationWaiter) async {
            await withCheckedContinuation { continuation in
                waiter.continuation = continuation
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        private func escapeHTML(_ text: String) -> String {
            text
                .replacing("&", with: "&amp;")
                .replacing("<", with: "&lt;")
                .replacing(">", with: "&gt;")
                .replacing("\"", with: "&quot;")
        }

        /// Converts parsed `MarkdownBlock`s into semantic HTML so WebKit's DOM
        /// text & block structure can be compared against `RowSelectableText`.
        private func renderHTML(_ blocks: [MarkdownBlock]) -> String {
            blocks.map(renderBlock).joined(separator: "\n")
        }

        private func renderBlock(_ block: MarkdownBlock) -> String {
            switch block {
            case .paragraph(let inlines):
                return "<p>\(renderInlines(inlines))</p>"
            case .heading(let level, let inlines):
                return "<h\(level)>\(renderInlines(inlines))</h\(level)>"
            case .code(_, let code):
                return "<pre><code>\(escapeHTML(code))</code></pre>"
            case .list(let list):
                let tag = list.startIndex != nil ? "ol" : "ul"
                let items = list.items.map { "<li>\(renderHTML($0.blocks))</li>" }.joined()
                return "<\(tag)>\(items)</\(tag)>"
            case .quote(let children):
                return "<blockquote>\(renderHTML(children))</blockquote>"
            case .table(let table):
                let head = "<tr>" + table.header.map { "<th>\(renderInlines($0))</th>" }.joined() + "</tr>"
                let body = table.rows.map { row in
                    "<tr>" + row.map { "<td>\(renderInlines($0))</td>" }.joined() + "</tr>"
                }.joined()
                return "<table><thead>\(head)</thead><tbody>\(body)</tbody></table>"
            case .rule:
                return "<hr>"
            }
        }

        private func renderInlines(_ inlines: [MarkdownInline]) -> String {
            inlines.map { inline in
                var html = escapeHTML(inline.text)
                if inline.style.contains(.code) { html = "<code>\(html)</code>" }
                if inline.style.contains(.strong) { html = "<strong>\(html)</strong>" }
                if inline.style.contains(.emphasis) { html = "<em>\(html)</em>" }
                if inline.style.contains(.strikethrough) { html = "<del>\(html)</del>" }
                if let link = inline.link { html = "<a href=\"\(escapeHTML(link.absoluteString))\">\(html)</a>" }
                return html
            }.joined()
        }

        /// Fuzzed Markdown documents preserve identical block text content and
        /// order when rendered by our engine vs live WebKit DOM elements.
        @Test(arguments: 0..<2)
        func webKitBlockStructureAndTextMatchMarkdownPlanner(seed: Int) async throws {
            let style = TextStyle.current()
            let (webView, waiter) = makeWebView()
            var rng = FuzzRNG(seed: 0x0FAC_1E00 &+ UInt64(seed))

            for iteration in 0..<(3 * TranscriptFuzz.scale) {
                let source = TranscriptFuzz.markdownDocument(&rng, blocks: rng.int(in: 3..<12))
                let blocks = MarkdownPlanner.blocks(from: source)
                let html = """
                    <!doctype html><html><body style="margin:0;width:600px;font:14px -apple-system;">
                    <div id="root">\(renderHTML(blocks))</div>
                    </body></html>
                    """
                await load(html, in: webView, waiter: waiter)

                let js = """
                    Array.from(document.querySelectorAll('#root > *')).map(el => {
                        if (el.tagName === 'PRE') return { tag: 'PRE', text: el.textContent };
                        if (el.tagName === 'TABLE') {
                            const rows = Array.from(el.querySelectorAll('tr')).map(tr =>
                                Array.from(tr.children).map(td => td.textContent).join('\\t')
                            );
                            return { tag: 'TABLE', text: rows.join('\\n') };
                        }
                        if (el.tagName === 'HR') return { tag: 'HR', text: '' };
                        return { tag: el.tagName, text: el.textContent };
                    });
                    """
                let raw = try await webView.evaluateJavaScript(js) as? [[String: String]]
                let domBlocks = try #require(raw)
                #expect(domBlocks.count == blocks.count, "seed \(seed) iter \(iteration): block count mismatch")

                for (index, (block, dom)) in zip(blocks, domBlocks).enumerated() {
                    let row = TranscriptRow(id: "r#\(index)", kind: .markdownBlock(block, .of(index, in: blocks)))
                    let ours = RowSelectableText.string(for: row.kind, style: style) ?? ""
                    let expectedTag: String
                    switch block {
                    case .paragraph: expectedTag = "P"
                    case .heading(let level, _): expectedTag = "H\(level)"
                    case .code: expectedTag = "PRE"
                    case .list(let list): expectedTag = list.startIndex != nil ? "OL" : "UL"
                    case .quote: expectedTag = "BLOCKQUOTE"
                    case .table: expectedTag = "TABLE"
                    case .rule: expectedTag = "HR"
                    }
                    #expect(dom["tag"] == expectedTag, "seed \(seed) iter \(iteration) block \(index)")
                    switch block {
                    case .paragraph, .heading, .code, .table:
                        #expect(
                            ours == (dom["text"] ?? ""),
                            "seed \(seed) iter \(iteration) block \(index) (\(expectedTag)) text diverged")
                    case .list, .quote, .rule:
                        // Lists/quotes add bullets/numbers or newlines between nested blocks in plain text;
                        // verify non-empty content survives in both.
                        let domText = (dom["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !domText.isEmpty {
                            #expect(!ours.isEmpty, "seed \(seed) iter \(iteration) block \(index) lost text")
                        }
                    }
                }
            }
        }

        /// Compares `TranscriptController.wordRange(around:)` and
        /// `paragraphRange(around:)` against WebKit's `Selection.modify`
        /// across fuzzed Latin, numeric, punctuation, emoji, and multi-paragraph text.
        @Test func webKitWordAndParagraphRangesMatchController() async throws {
            let (webView, waiter) = makeWebView()
            let samples = [
                "The quick brown fox jumps over 42 lazy dogs.",
                "hello_world camelCase foo-bar-baz 3.14159 end",
                "First paragraph line.\nSecond paragraph with café and 👩🏽‍💻 emoji.",
                "Alpha beta gamma.\nDelta epsilon zeta.",
            ]
            for sample in samples {
                let html = """
                    <!doctype html><html><body style="margin:0;width:600px;font:14px -apple-system;">
                    <p id="p" style="white-space:pre-wrap;">\(escapeHTML(sample))</p>
                    </body></html>
                    """
                await load(html, in: webView, waiter: waiter)

                let controller = TranscriptController(configuration: .testing)
                let row = TranscriptRow(id: "r0", kind: .markdownBlock(.paragraph([MarkdownInline(text: sample)]), .single))
                controller.setRows([row])

                // Check paragraph range at each hard-line start against the
                // line bounds (newline-delimited, as WebKit's paragraph boundary).
                let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)
                var utf16Cursor = 0
                for line in lines {
                    let pos = TextPosition(rowID: "r0", offset: utf16Cursor)
                    let para = try #require(controller.paragraphRange(around: pos))
                    #expect(para.anchor.offset == utf16Cursor)
                    #expect(para.focus.offset == utf16Cursor + line.utf16.count)
                    utf16Cursor += line.utf16.count + 1
                }

                // Probe word selection on alphanumeric word interiors against WebKit.
                let ns = sample as NSString
                var probeOffsets: [Int] = []
                ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { sub, range, _, _ in
                    guard let sub, sub.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }),
                        range.length >= 2
                    else { return }
                    probeOffsets.append(range.location + range.length / 2)
                }
                for offset in probeOffsets {
                    let js = """
                        (() => {
                            const node = document.getElementById('p').firstChild;
                            const sel = window.getSelection();
                            sel.removeAllRanges();
                            const r = document.createRange();
                            r.setStart(node, \(offset));
                            r.collapse(true);
                            sel.addRange(r);
                            sel.modify('move', 'backward', 'word');
                            sel.modify('extend', 'forward', 'word');
                            return sel.toString();
                        })()
                        """
                    let webWord = (try await webView.evaluateJavaScript(js) as? String) ?? ""
                    let oursRange = try #require(controller.wordRange(around: TextPosition(rowID: "r0", offset: offset)))
                    let oursWord = controller.text(from: oursRange.anchor, to: oursRange.focus)
                    #expect(oursWord == webWord, "word mismatch at offset \(offset) in \(sample.debugDescription)")
                }
            }
        }

        /// Verifies RTL `dir="auto"` parity: both WebKit (`<p dir="auto">`)
        /// and our `TextLayoutEngine` right-align RTL paragraphs flush with the
        /// container's trailing edge.
        @Test func webKitRTLDirAutoRightAlignmentMatchesEngine() async throws {
            let arabic = "مرحباً بالعالم، هذا اختبار لمحاذاة النص العربي."
            let width: CGFloat = 600
            let (webView, waiter) = makeWebView(width: width, height: 200)
            let html = """
                <!doctype html><html><body style="margin:0;width:\(Int(width))px;font:14px -apple-system;">
                <p id="rtl" dir="auto" style="margin:0;width:\(Int(width))px;">\(arabic)</p>
                </body></html>
                """
            await load(html, in: webView, waiter: waiter)
            let js = """
                (() => {
                    const node = document.getElementById('rtl').firstChild;
                    const r = document.createRange();
                    r.selectNodeContents(node);
                    const rect = r.getBoundingClientRect();
                    return { left: rect.left, right: rect.right, width: rect.width };
                })()
                """
            let rect = try #require(try await webView.evaluateJavaScript(js) as? [String: Double])
            let webRight = try #require(rect["right"])
            let webLeft = try #require(rect["left"])
            #expect(webRight > Double(width) - 20)
            #expect(webLeft > Double(width) * 0.4)

            let style = TextStyle.current()
            let layout = RowLayoutBuilder.prose([.paragraph([MarkdownInline(text: arabic)])], width: width, style: style)
            let firstLine = try #require(layout.lines.first)
            #expect(abs((firstLine.x + firstLine.width) - width) < 1)
            #expect(firstLine.x > width * 0.4)
        }
    }
#endif
