import Foundation
import SwiftUI
#if os(iOS)
import WebKit
#endif

struct ACPRegistryRow: View {
    let entry: ACPRegistryEntry
    let isInstalling: Bool
    let install: () -> Void

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
            }

            Spacer(minLength: 0)

            ACPRegistryRowAction(
                entry: entry,
                isInstalling: isInstalling,
                install: install
            )
        }
        .contentShape(.rect)
    }
}

private struct ACPRegistryIcon: View {
    let iconURL: URL?

    var body: some View {
        Group {
            if let iconURL {
                ACPRegistryIconContent(iconURL: iconURL)
            } else {
                fallbackGlyph
            }
        }
        .frame(width: 28, height: 28)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

private var fallbackGlyph: some View {
    Image(systemName: "puzzlepiece.extension")
        .imageScale(.large)
}

private struct ACPRegistryIconContent: View {
    let iconURL: URL

    var body: some View {
        #if os(iOS)
        ACPRegistrySVGIcon(iconURL: iconURL)
        #else
        AsyncImage(url: iconURL) { image in
            image
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
        } placeholder: {
            // Persists when the load fails, so the slot never goes blank.
            fallbackGlyph
        }
        #endif
    }
}

#if os(iOS)
private struct ACPRegistrySVGIcon: UIViewRepresentable {
    let iconURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
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

    @MainActor
    final class Coordinator {
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
#endif

struct ACPRegistryRowAction: View {
    let entry: ACPRegistryEntry
    let isInstalling: Bool
    let install: () -> Void

    var body: some View {
        if isInstalling {
            ProgressView()
                .controlSize(.small)
        } else if !entry.isInstalled {
            Button("Install", action: install)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(entry.availableVersion == nil)
        } else if entry.hasUpdate {
            Button("Update", action: install)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        } else {
            Label("Installed", systemImage: "checkmark")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Installed")
        }
    }
}
