import Foundation
import SwiftUI
import WebKit

struct ACPRegistryRow: View {
    let entry: ACPRegistryEntry
    let isBusy: Bool
    let install: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Always present so text lines up across rows with remote
            // icons, rows whose icon failed to load, and custom agents.
            ACPRegistryIcon(iconURL: entry.iconURL)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let description = entry.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
                if !entry.versionLabel.isEmpty {
                    Text(entry.versionLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                if let blockerMessage = entry.blockerMessage {
                    Text(blockerMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if entry.state == .failed, let errorMessage = entry.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .foregroundStyle(.red)
                }
                ACPRegistryRowLinks(entry: entry)
            }

            Spacer(minLength: 0)

            ACPRegistryRowAction(
                entry: entry,
                isBusy: isBusy,
                install: install,
                edit: edit,
                remove: remove
            )
        }
        .contentShape(.rect)
    }
}

private struct ACPRegistryRowLinks: View {
    let entry: ACPRegistryEntry

    var body: some View {
        HStack(spacing: 12) {
            if let url = entry.repositoryURL {
                link("Repository", systemImage: "chevron.left.forwardslash.chevron.right", url)
            }
            if let url = entry.websiteURL {
                link("Website", systemImage: "globe", url)
            }
            if let url = entry.licenseURL {
                link("License", systemImage: "doc.text", url)
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }

    private func link(_ title: LocalizedStringKey, systemImage: String, _ url: URL) -> some View {
        Link(destination: url) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .help(title)
        .foregroundStyle(.secondary)
    }
}

private struct ACPRegistryIcon: View {
    let iconURL: URL?

    var body: some View {
        Group {
            if let iconURL {
                ACPRegistrySVGIcon(iconURL: iconURL)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .imageScale(.large)
            }
        }
        .frame(width: 28, height: 28)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

#if os(macOS)
    private struct ACPRegistrySVGIcon: NSViewRepresentable {
        let iconURL: URL

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeNSView(context: Context) -> WKWebView {
            let webView = WKWebView(
                frame: .zero,
                configuration: Self.configuration()
            )
            // AppKit WKWebView has no isOpaque/backgroundColor surface;
            // this documented key is the supported transparency switch.
            webView.setValue(false, forKey: "drawsBackground")
            return webView
        }

        func updateNSView(_ webView: WKWebView, context: Context) {
            context.coordinator.load(iconURL, in: webView)
        }
    }
#else
    private struct ACPRegistrySVGIcon: UIViewRepresentable {
        let iconURL: URL

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIView(context: Context) -> WKWebView {
            let webView = WKWebView(
                frame: .zero,
                configuration: Self.configuration()
            )
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.isScrollEnabled = false
            webView.isUserInteractionEnabled = false
            return webView
        }

        func updateUIView(_ webView: WKWebView, context: Context) {
            context.coordinator.load(iconURL, in: webView)
        }
    }
#endif

extension ACPRegistrySVGIcon {
    fileprivate static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        return configuration
    }

    @MainActor
    final class Coordinator {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        private var currentURL: URL?
        private var loadTask: Task<Void, Never>?

        func load(_ url: URL, in webView: WKWebView) {
            guard currentURL != url else { return }
            currentURL = url
            loadTask?.cancel()
            loadTask = Task { [weak self, weak webView] in
                guard
                    let (data, response) = try? await URLSession.shared.data(from: url),
                    !Task.isCancelled,
                    self?.currentURL == url,
                    let response = response as? HTTPURLResponse,
                    200..<300 ~= response.statusCode,
                    let svg = String(data: data, encoding: .utf8),
                    let webView
                else { return }
                webView.loadHTMLString(Self.html(svg: svg), baseURL: nil)
            }
        }

        private static func html(svg: String) -> String {
            """
            <!doctype html>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              :root { color-scheme: light dark; }
              html, body { margin: 0; width: 100%; height: 100%; color: -apple-system-secondary-label; }
              svg { display: block; width: 100%; height: 100%; }
            </style>
            \(svg)
            """
        }
    }
}

struct ACPRegistryRowAction: View {
    let entry: ACPRegistryEntry
    let isBusy: Bool
    let install: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            status
            if entry.isInstalled {
                manageMenu
            }
        }
    }

    private var manageMenu: some View {
        Menu("Manage \(entry.name)", systemImage: "ellipsis.circle") {
            if entry.source == .custom {
                Button("Edit…", systemImage: "pencil", action: edit)
            }
            Button("Remove…", systemImage: "trash", role: .destructive, action: remove)
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
        .disabled(isBusy)
    }

    @ViewBuilder
    private var status: some View {
        if entry.isWorking {
            ProgressView {
                Text(entry.state == .updating ? "Updating…" : "Installing…")
                    .font(.caption)
            }
            .controlSize(.small)
        } else if isBusy {
            ProgressView()
                .controlSize(.small)
        } else if entry.state == .failed, entry.availableVersion != nil {
            actionButton("Retry", prominent: false)
        } else if !entry.isInstalled {
            actionButton("Install", prominent: false)
        } else if entry.hasUpdate {
            actionButton("Update", prominent: true)
        } else {
            Label("Installed", systemImage: "checkmark")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Installed")
        }
    }

    @ViewBuilder
    private func actionButton(_ title: LocalizedStringKey, prominent: Bool) -> some View {
        let isAvailable = entry.availableVersion != nil && entry.blocker == nil
        if prominent {
            Button(title, action: install)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(!isAvailable)
        } else {
            Button(title, action: install)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(!isAvailable)
        }
    }
}
