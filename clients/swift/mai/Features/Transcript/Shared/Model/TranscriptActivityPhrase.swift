import CoreGraphics
import Foundation

/// What a provider stated an activity entry did, for a group's one-line
/// summary such as "Read files, ran a command, github · list_issues". Only
/// stated facts count: the entry kind, or a read/search action the provider
/// declared; any other tool is named by its raw name.
nonisolated enum TranscriptActivityPhrase: Hashable, Sendable {
    case thought, read, searched, edited, ranCommand
    case tool(String)

    init(_ entry: EntryView) {
        switch entry.tool?.action.flatMap(MaidToolAction.init(rawValue:)) {
        case .read: self = .read
        case .search: self = .searched
        case nil:
            switch entry.itemKind {
            case .reasoning: self = .thought
            case .commandExecution: self = .ranCommand
            case .fileChange: self = .edited
            default:
                if let name = entry.tool?.name, !name.isEmpty {
                    let namespace = entry.tool?.namespace ?? ""
                    self = .tool(namespace.isEmpty ? name : "\(namespace) · \(name)")
                } else {
                    self = .tool(entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? entry.kind)
                }
            }
        }
    }

    func text(count: Int, leading: Bool) -> String {
        let text: String
        switch self {
        case .thought: text = "thought"
        case .read: text = count == 1 ? "read a file" : "read files"
        case .searched: text = "searched"
        case .edited: text = count == 1 ? "edited a file" : "edited files"
        case .ranCommand: text = count == 1 ? "ran a command" : "ran commands"
        case .tool(let name): return name
        }
        return leading ? text.prefix(1).uppercased() + text.dropFirst() : text
    }

    /// At most three tool names show before "+N more".
    static func summary(_ phrases: [TranscriptActivityPhrase]) -> String {
        var counts: [(phrase: TranscriptActivityPhrase, count: Int)] = []
        for phrase in phrases {
            if let index = counts.firstIndex(where: { $0.phrase == phrase }) {
                counts[index].count += 1
            } else {
                counts.append((phrase, 1))
            }
        }
        var parts: [String] = []
        var tools = 0
        for (phrase, count) in counts {
            if case .tool = phrase {
                tools += 1
                guard tools <= 3 else { continue }
            }
            parts.append(phrase.text(count: count, leading: parts.isEmpty))
        }
        if tools > 3 { parts.append("+\(tools - 3) more") }
        return parts.joined(separator: ", ")
    }
}
