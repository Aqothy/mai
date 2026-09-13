import SwiftUI

struct ProviderAccountsView: View {
    private struct Destination: Hashable {
        let providerID: String
    }

    let store: ThreadStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(store.availableProviders) { choice in
                    NavigationLink(value: Destination(providerID: choice.id)) {
                        VStack(alignment: .leading) {
                            Text(choice.name)
                            if let status = store.providerInfo(for: choice.id)?.auth.status {
                                Text(status.replacing("_", with: " ").capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text(
                    "Opening a provider starts it so its available sign-in methods can be read."
                )
            }
        }
        .overlay {
            if store.availableProviders.isEmpty {
                ContentUnavailableView(
                    "No Providers Available",
                    systemImage: "person.crop.circle.badge.questionmark"
                )
            }
        }
        .navigationTitle("Provider Accounts")
        .inlineNavigationBarTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .navigationDestination(for: Destination.self) { destination in
            ProviderAccountDetailView(
                providerID: destination.providerID,
                store: store
            )
        }
    }
}
