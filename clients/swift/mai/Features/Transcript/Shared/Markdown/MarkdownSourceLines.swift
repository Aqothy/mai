import CoreGraphics
import Foundation
import Markdown

/// UTF-8 line starts of a source, for swift-markdown's 1-based line and
/// byte-column locations.
nonisolated struct MarkdownSourceLines {
    let bytes: [UInt8]
    let starts: [Int]

    init(_ source: String) {
        bytes = Array(source.utf8)
        var starts = [0]
        for (offset, byte) in bytes.enumerated() where byte == 0x0A { starts.append(offset + 1) }
        self.starts = starts
    }

    func utf8Offset(line: Int, column: Int) -> Int? {
        guard starts.indices.contains(line - 1) else { return nil }
        let offset = starts[line - 1] + column - 1
        return offset <= bytes.count ? offset : nil
    }

    /// A thematic break as its author typed it (`---`, `***`, `___`).
    func spelling(of rule: ThematicBreak) -> String? {
        guard let location = rule.range?.lowerBound,
            let start = utf8Offset(line: location.line, column: location.column)
        else { return nil }
        let end = starts.indices.contains(location.line) ? starts[location.line] - 1 : bytes.count
        guard start <= end else { return nil }
        return String(decoding: bytes[start..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
