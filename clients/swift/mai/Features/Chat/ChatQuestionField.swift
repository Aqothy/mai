import SwiftUI

/// One question of an agent's form: options to pick from, or a value to enter.
struct ChatQuestionField: View {
    let question: Question
    let model: ChatRequestModel

    var body: some View {
        VStack(alignment: .leading) {
            Text(question.title ?? question.id)
                .font(.callout)
                .bold()
            if let description = question.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if question.questionKind == .choice {
                ForEach(question.options ?? [], id: \.value) { option in
                    ChatQuestionOptionButton(
                        option: option,
                        isSelected: model.isSelected(option, in: question),
                        allowsMultiple: question.multiSelect == true
                    ) {
                        model.toggle(option, in: question)
                    }
                }
                if question.allowsFreeText == true {
                    TextField("Other", text: answerBinding)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                TextField(question.title ?? question.id, text: answerBinding)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(question.questionKind == .text ? .default : .numbersAndPunctuation)
                    #endif
            }

            if let message = model.validationMessage(for: question) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension ChatQuestionField {
    private var answerBinding: Binding<String> {
        Binding(
            get: { model.textAnswer(for: question) },
            set: { model.setTextAnswer($0, for: question) }
        )
    }
}

private struct ChatQuestionOptionButton: View {
    let option: QuestionOption
    let isSelected: Bool
    let allowsMultiple: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: symbol)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading) {
                    Text(option.label)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var symbol: String {
        switch (allowsMultiple, isSelected) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "largecircle.fill.circle"
        case (false, false): "circle"
        }
    }
}
