import SwiftUI

struct ProviderAccountDetailView: View {
    @Environment(\.openURL) private var openURL
    @State private var model: ProviderAccountModel

    init(providerID: String, store: ThreadStore) {
        _model = State(
            initialValue: ProviderAccountModel(providerID: providerID, store: store)
        )
    }

    var body: some View {
        @Bindable var model = model
        Form {
            if let provider = model.provider {
                Section("Provider") {
                    LabeledContent("Name", value: provider.name)
                    LabeledContent("Driver", value: provider.driver)
                    LabeledContent(
                        "Account",
                        value: provider.auth.status?.capitalized ?? "Unknown"
                    )
                }

                if model.isAuthenticated {
                    Section("Account") {
                        Label("Signed in", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if model.supportsLogout {
                            Button(
                                "Sign Out",
                                systemImage: "rectangle.portrait.and.arrow.right"
                            ) {
                                Task { await model.logout() }
                            }
                            .disabled(model.isLoggingOut)
                        }
                    }
                } else if model.supportsAuthentication {
                    Section("Sign In") {
                        if model.methods.isEmpty {
                            ContentUnavailableView(
                                "No Sign-In Methods",
                                systemImage: "person.crop.circle.badge.exclamationmark",
                                description: Text(
                                    "The provider did not report an available sign-in method."
                                )
                            )
                        } else {
                            ForEach(model.methods, id: \.id) { method in
                                Button {
                                    Task { await model.select(method) }
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(method.name ?? method.id)
                                        if let description = method.description {
                                            Text(description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .disabled(model.isAuthenticating)
                            }
                        }
                    }

                    if let method = model.selectedMethod, method.requiresSecret == true {
                        Section(method.name ?? "Secret") {
                            SecureField("Secret", text: $model.secret)
                                .textContentType(.password)
                                .privacySensitive()
                            Button(
                                "Sign In",
                                systemImage: "person.crop.circle.badge.checkmark"
                            ) {
                                Task { await model.authenticateSelectedMethod() }
                            }
                            .disabled(model.secret.isEmpty || model.isAuthenticating)
                        }
                    }
                } else {
                    Section("Account") {
                        ContentUnavailableView(
                            "Sign-In Unavailable",
                            systemImage: "person.crop.circle.badge.xmark",
                            description: Text(
                                "This provider does not advertise account management."
                            )
                        )
                    }
                }

                if let challenge = model.challenge {
                    Section("Continue Sign In") {
                        if let userCode = challenge.userCode {
                            LabeledContent("Device Code") {
                                Text(userCode)
                                    .monospaced()
                                    .textSelection(.enabled)
                            }
                            .accessibilityHint("Select the code to copy it")
                        }
                        if let challengeURL = model.challengeURL {
                            Button("Open Sign-In Page", systemImage: "safari") {
                                openURL(challengeURL)
                            }
                        }
                        Button("Check Sign-In Status", systemImage: "arrow.clockwise") {
                            Task { await model.refresh() }
                        }
                    }
                }
            }
        }
        .overlay {
            switch model.phase {
            case .loading:
                ProgressView("Starting Provider…")
            case .failed(let message):
                ContentUnavailableView {
                    Label("Account Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry", systemImage: "arrow.clockwise") {
                        Task { await model.load() }
                    }
                }
            case .loaded:
                EmptyView()
            }
        }
        .navigationTitle(model.provider?.name ?? "Provider Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .disabled(model.phase != .loaded)
            }
        }
        .task { await model.load() }
        .onChange(of: model.challengeURL) { _, challengeURL in
            if let challengeURL {
                openURL(challengeURL)
            }
        }
        .alert("Provider Account Error", isPresented: $model.isErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "An unknown error occurred.")
        }
    }
}
