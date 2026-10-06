import Foundation
import Observation

@Observable
final class ProviderAccountModel {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    let providerID: String

    private(set) var phase: Phase = .loading
    private(set) var provider: InstanceInfo?
    private(set) var challenge: AuthChallenge?
    private(set) var isAuthenticating = false
    private(set) var isLoggingOut = false
    private(set) var errorMessage: String?
    var selectedMethodID: String?
    var secret = ""

    private let store: ThreadStore

    init(providerID: String, store: ThreadStore) {
        self.providerID = providerID
        self.store = store
    }

    var methods: [AuthMethod] {
        provider?.auth.methods ?? []
    }

    var isAuthenticated: Bool {
        provider?.auth.status == MaidAuthStatus.authenticated.rawValue
    }

    var supportsAuthentication: Bool {
        provider?.capabilities.auth == true
    }

    var supportsLogout: Bool {
        provider?.capabilities.logout == true
    }

    var selectedMethod: AuthMethod? {
        guard let selectedMethodID else { return nil }
        return methods.first { $0.id == selectedMethodID }
    }

    var challengeURL: URL? {
        let rawURL = challenge?.url ?? challenge?.verificationURL
        guard let rawURL,
            let url = URL(string: rawURL),
            url.scheme == "https" || url.scheme == "http"
        else { return nil }
        return url
    }

    var isErrorPresented: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    func load() async {
        phase = .loading
        do {
            provider = try await store.prepareProviderAccount(providerID)
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func select(_ method: AuthMethod) async {
        if selectedMethodID != method.id {
            secret = ""
        }
        selectedMethodID = method.id
        guard method.requiresSecret != true else { return }
        await authenticate(using: method)
    }

    func authenticateSelectedMethod() async {
        guard let selectedMethod else { return }
        await authenticate(using: selectedMethod)
    }

    func refresh() async {
        do {
            provider = try await store.refreshProviderAccount(providerID)
            if isAuthenticated {
                challenge = nil
                secret = ""
                selectedMethodID = nil
            }
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logout() async {
        guard !isLoggingOut else { return }
        isLoggingOut = true
        defer { isLoggingOut = false }
        do {
            provider = try await store.logoutProvider(providerID)
            challenge = nil
            secret = ""
            selectedMethodID = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func authenticate(using method: AuthMethod) async {
        guard !isAuthenticating else { return }
        let submittedSecret: String?
        if method.requiresSecret == true {
            guard !secret.isEmpty else {
                errorMessage = String(
                    localized: "Enter the secret required by this sign-in method."
                )
                return
            }
            submittedSecret = secret
            secret = ""
        } else {
            submittedSecret = nil
        }

        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let result = try await store.authenticateProvider(
                providerID: providerID,
                methodID: method.id,
                secret: submittedSecret
            )
            provider = result.instance
            challenge = result.challenge
            if isAuthenticated {
                selectedMethodID = nil
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
