import Foundation
import Observation

/// Form state for an agent question (a user-input request): typed answers,
/// choice selections, and the response sent back through `send`.
@Observable
final class ChatQuestionModel {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    /// Delivers a response: the approval command for a question in a chat,
    /// or the sign-in answer for one asked while signing in.
    typealias Send = (MaidApprovalDecision, [String: [String]]?) async throws -> Void

    let request: UserInputRequest
    @ObservationIgnored private let send: Send
    private(set) var isResponding = false
    private(set) var errorMessage: String?

    /// Entered values for text, number and integer questions, and the typed
    /// answer of choice questions that allow one.
    private(set) var textAnswers: [String: String] = [:]
    /// Selected option values for choice questions.
    private(set) var choiceAnswers: [String: Set<String>] = [:]

    init(request: UserInputRequest, send: @escaping Send) {
        self.request = request
        self.send = send
        for question in request.questions ?? [] {
            guard let defaults = question.questionDefault, !defaults.isEmpty else { continue }
            if question.questionKind == .choice {
                choiceAnswers[question.id] = Set(defaults)
            } else {
                textAnswers[question.id] = defaults[0]
            }
        }
    }

    var questions: [Question] { request.questions ?? [] }

    /// The request's message with inline Markdown rendered and its line
    /// breaks kept: a plan under review is a Markdown document.
    var messageText: AttributedString {
        (try? AttributedString(
            markdown: request.message,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(request.message)
    }

    /// The http(s) URL a URL-mode request asks to open, if valid.
    var url: URL? {
        guard let raw = request.url, let url = URL(string: raw),
            url.scheme == "https" || url.scheme == "http", url.host() != nil
        else { return nil }
        return url
    }

    /// Punycode hosts can imitate other domains, so they get a warning.
    var hasSuspiciousHost: Bool {
        url?.host()?.split(separator: ".").contains { $0.hasPrefix("xn--") } == true
    }

    var canSubmit: Bool {
        !isResponding && questions.allSatisfy { validationMessage(for: $0) == nil }
    }

    func isSelected(_ option: QuestionOption, in question: Question) -> Bool {
        choiceAnswers[question.id]?.contains(option.value) == true
    }

    func toggle(_ option: QuestionOption, in question: Question) {
        var selected = choiceAnswers[question.id] ?? []
        if question.multiSelect == true {
            if selected.remove(option.value) == nil {
                selected.insert(option.value)
            }
        } else {
            selected = [option.value]
            // One answer only: choosing an option replaces a typed one.
            textAnswers[question.id] = nil
        }
        choiceAnswers[question.id] = selected
    }

    func textAnswer(for question: Question) -> String {
        textAnswers[question.id] ?? ""
    }

    func setTextAnswer(_ text: String, for question: Question) {
        textAnswers[question.id] = text
        // One answer only: typing an answer replaces a chosen option.
        if question.questionKind == .choice, question.multiSelect != true,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            choiceAnswers[question.id] = nil
        }
    }

    /// Why the current answer can't be submitted, or nil when it can.
    func validationMessage(for question: Question) -> String? {
        let values = answerValues(for: question)
        if values.isEmpty {
            return question.questionRequired == true
                ? String(localized: "Required") : nil
        }
        switch question.questionKind {
        case .number:
            return Double(values[0]) == nil ? String(localized: "Enter a number") : nil
        case .integer:
            return Int(values[0]) == nil ? String(localized: "Enter a whole number") : nil
        default:
            return nil
        }
    }

    /// The answers Submit sends: one entry per answered question.
    var answers: [String: [String]] {
        Dictionary(
            uniqueKeysWithValues: questions.compactMap { question in
                let values = answerValues(for: question)
                return values.isEmpty ? nil : (question.id, values)
            }
        )
    }

    /// One submitted answer as shown once the question is resolved.
    struct SubmittedAnswer: Identifiable {
        let id: String
        let title: String
        let answer: String
    }

    /// Submitted answers in question order, each with its question's title and
    /// the chosen options' labels (typed answers as written).
    func submittedAnswers(_ answers: [String: [String]]) -> [SubmittedAnswer] {
        questions.compactMap { question in
            guard let values = answers[question.id], !values.isEmpty else { return nil }
            let labels = values.map { value in
                question.options?.first { $0.value == value }?.label ?? value
            }
            return SubmittedAnswer(
                id: question.id,
                title: question.title ?? question.id,
                answer: labels.formatted(.list(type: .and))
            )
        }
    }

    func submit() async {
        await respond(.accept, answers: answers)
    }

    func respond(_ decision: MaidApprovalDecision, answers: [String: [String]]? = nil) async {
        guard !isResponding else { return }
        isResponding = true
        errorMessage = nil
        defer { isResponding = false }
        do {
            try await send(decision, answers)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Choice answers keep the options' order, followed by a typed answer when
    /// the question allows one. Typed answers are trimmed.
    private func answerValues(for question: Question) -> [String] {
        let text = textAnswers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard question.questionKind == .choice else {
            return text.isEmpty ? [] : [text]
        }
        let selected = choiceAnswers[question.id] ?? []
        let options = (question.options ?? []).map(\.value).filter(selected.contains)
        guard question.allowsFreeText == true, !text.isEmpty else { return options }
        return options + [text]
    }
}

extension Question {
    var questionKind: MaidQuestionKind? { MaidQuestionKind(rawValue: kind) }
}
