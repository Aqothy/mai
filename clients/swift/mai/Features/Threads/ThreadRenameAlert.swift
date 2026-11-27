import SwiftUI

/// Asks for a new title for a thread and renames it, reporting a failure.
struct ThreadRenameAlert: ViewModifier {
    @Binding var isPresented: Bool
    let currentTitle: String
    let rename: (String) async throws -> Void

    @State private var title = ""
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .alert("Rename Chat", isPresented: $isPresented) {
                TextField("Title", text: $title)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    let title = title
                    Task {
                        do {
                            try await rename(title)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .onChange(of: isPresented) { _, presented in
                if presented {
                    title = currentTitle
                }
            }
            .alert(
                "Couldn’t Rename Chat",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }
}

extension View {
    func threadRenameAlert(
        isPresented: Binding<Bool>,
        currentTitle: String,
        rename: @escaping (String) async throws -> Void
    ) -> some View {
        modifier(ThreadRenameAlert(isPresented: isPresented, currentTitle: currentTitle, rename: rename))
    }
}
