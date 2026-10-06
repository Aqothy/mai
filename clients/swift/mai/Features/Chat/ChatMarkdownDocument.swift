import Markdown

extension Markdown.Document {
    /// Parses chat Markdown as written. Smart punctuation would turn quotes,
    /// `--` and `...` in prose into typographic characters, so displayed and
    /// copied text would no longer match commands and flags in the source.
    nonisolated init(chatSource source: String) {
        self.init(parsing: source, options: .disableSmartOpts)
    }
}
