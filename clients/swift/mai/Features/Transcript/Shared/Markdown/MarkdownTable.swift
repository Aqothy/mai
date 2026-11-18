import CoreGraphics
import Foundation

nonisolated struct MarkdownTable: Hashable, Sendable {
    enum Alignment: Hashable, Sendable {
        case leading, center, trailing
    }

    var alignments: [Alignment]
    var header: [[MarkdownInline]]
    var rows: [[[MarkdownInline]]]

    var columnCount: Int { max(header.count, rows.lazy.map(\.count).max() ?? 0) }
}
