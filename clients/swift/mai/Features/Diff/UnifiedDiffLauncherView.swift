import SwiftUI

struct UnifiedDiffLauncherView: View {
    let changes: [FileChange]

    @State private var isPresented = false

    var body: some View {
        Button(
            "View ^[\(changes.count) file change](inflect: true)",
            systemImage: "doc.text.magnifyingglass"
        ) {
            isPresented = true
        }
        .sheet(isPresented: $isPresented) {
            UnifiedDiffView(changes: changes)
                .presentationDragIndicator(.visible)
        }
    }
}
