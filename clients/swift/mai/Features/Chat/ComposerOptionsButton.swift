import SwiftUI

struct ComposerOptionsButton<SheetContent: View>: View {
    let summary: String
    @Binding var isPresented: Bool
    let isDisabled: Bool
    let sheetContent: SheetContent

    init(
        summary: String,
        isPresented: Binding<Bool>,
        isDisabled: Bool = false,
        @ViewBuilder sheetContent: () -> SheetContent
    ) {
        self.summary = summary
        _isPresented = isPresented
        self.isDisabled = isDisabled
        self.sheetContent = sheetContent()
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Text(summary)
                .lineLimit(1)
                .contentTransition(.numericText())
                .frame(minHeight: 36)
        }
        .font(.callout)
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel("Model options")
        .sheet(isPresented: $isPresented) {
            sheetContent
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}
