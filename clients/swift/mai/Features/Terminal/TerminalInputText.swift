/// Text normalization that belongs at the platform text-input boundary.
/// Terminal Enter is carriage return; line feed remains available as Ctrl-J.
nonisolated enum TerminalInputText {
    static func normalizingSoftwareReturn(_ text: String) -> String {
        switch text {
        case "\n", "\r\n": "\r"
        default: text
        }
    }
}
