import Foundation
import Testing

@testable import mai

struct ChatQuestionModelTests {
    private func request(_ json: String) throws -> UserInputRequest {
        try newJSONDecoder().decode(UserInputRequest.self, from: Data(json.utf8))
    }

    @Test
    func defaultsPrefillAndAnswersKeepOptionOrder() throws {
        let model = ChatQuestionModel(request: try request("""
            {"message":"Configure","questions":[
              {"id":"tags","kind":"choice","multiSelect":true,"default":["b"],
               "options":[{"value":"a","label":"A"},{"value":"b","label":"B"},{"value":"c","label":"C"}]},
              {"id":"name","kind":"text","default":["maiD"]}
            ]}
            """))
        let tags = model.questions[0]
        // Selecting in reverse order still answers in the options' order.
        model.toggle(tags.options![2], in: tags)
        model.toggle(tags.options![0], in: tags)
        #expect(model.answers == ["tags": ["a", "b", "c"], "name": ["maiD"]])
        #expect(model.canSubmit)
    }

    @Test
    func requiredAndNumericAnswersBlockSubmit() throws {
        let model = ChatQuestionModel(request: try request("""
            {"message":"Count","questions":[{"id":"count","kind":"integer","required":true}]}
            """))
        let count = model.questions[0]
        #expect(model.validationMessage(for: count) != nil)

        model.setTextAnswer("2.5", for: count)
        #expect(!model.canSubmit)

        model.setTextAnswer(" 3 ", for: count)
        #expect(model.validationMessage(for: count) == nil)
        #expect(model.answers == ["count": ["3"]])
    }

    @Test
    func typedAnswerReplacesSingleChoice() throws {
        let model = ChatQuestionModel(request: try request("""
            {"message":"Pick","questions":[{"id":"q","kind":"choice","allowsFreeText":true,"required":true,
              "options":[{"value":"A","label":"A"},{"value":"B","label":"B"}]}]}
            """))
        let question = model.questions[0]
        model.toggle(question.options![0], in: question)
        model.setTextAnswer("Neither", for: question)
        #expect(!model.isSelected(question.options![0], in: question))
        #expect(model.answers == ["q": ["Neither"]])
        model.toggle(question.options![1], in: question)
        #expect(model.answers == ["q": ["B"]])
    }

    @Test
    func submittedAnswersShowOptionLabels() throws {
        let model = ChatQuestionModel(request: try request("""
            {"message":"Pick","questions":[
              {"id":"color","kind":"choice","title":"Color","options":[{"value":"b","label":"Blue"}]},
              {"id":"note","kind":"text"}
            ]}
            """))
        let shown = model.submittedAnswers(["note": ["Thanks"], "color": ["b"]])
        #expect(shown.map(\.title) == ["Color", "note"])
        #expect(shown.map(\.answer) == ["Blue", "Thanks"])
    }

    @Test
    func urlRequestsOnlyAcceptWebLinks() throws {
        #expect(ChatQuestionModel(request: try request(#"{"message":"Sign in","url":"https://xn--80ak6aa92e.com/a"}"#)).hasSuspiciousHost)
        #expect(ChatQuestionModel(request: try request(#"{"message":"Run","url":"file:///etc/passwd"}"#)).url == nil)
    }
}
