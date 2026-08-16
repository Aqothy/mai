import SwiftUI

/// Product detail screen for one terminal thread: the Ghostty surface plus
/// minimal chrome. The surface, status overlay, and toolbar stay separate
/// view structs so lifecycle changes never rebuild the terminal host.
///
/// Detach is navigation-driven: containers close the store's active terminal
/// when the visible content stops being a terminal, so no view-lifecycle
/// ordering can accidentally detach a terminal that was just reopened.
struct TerminalThreadScreen: View {
    let store: TerminalStore
    let request: TerminalOpenRequest
    /// Tells the container the created terminal's identity so navigation can
    /// point at the persisted row.
    var onCreated: ((String) -> Void)? = nil
    var onDeleted: (() -> Void)? = nil

    @State private var isRenamePresented = false
    @State private var renameTitle = ""
    @State private var isTerminateConfirmationPresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isDeleteErrorPresented = false
    @State private var deleteErrorMessage = ""
    @State private var isDeletingExitedTerminal = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var attachment: TerminalAttachment? {
        guard let active = store.activeAttachment, active.matches(request) else {
            return nil
        }
        return active
    }

    private var summary: TerminalSummary? {
        guard let terminalID = attachment?.terminalID else { return nil }
        return store.summary(for: terminalID)
    }

    var body: some View {
        Group {
            if let attachment {
                TerminalThreadView(
                    controller: attachment.controller,
                    title: summary?.displayTitle ?? String(localized: "Terminal")
                )
                // Each attachment renders through its own Ghostty session;
                // switching terminals must rebuild the surface rather than
                // feed a new byte stream into an old grid.
                .id(ObjectIdentifier(attachment))
                .overlay(alignment: .center) {
                    ZStack {
                        if !attachment.hasInstalledInitialSnapshot {
                            Rectangle()
                                .fill(MaidTerminalAppearance.background(for: colorScheme))
                                .ignoresSafeArea()
                        }
                        if attachment.phase == .attaching,
                            !attachment.hasInstalledInitialSnapshot
                        {
                            ProgressView("Opening Terminal…")
                        } else {
                            TerminalAttachmentOverlay(
                                phase: attachment.phase,
                                canRelaunch: attachment.terminalID != nil,
                                relaunch: { store.relaunchActiveTerminal() }
                            )
                        }
                    }
                }
                .toolbar {
                    TerminalActionsToolbar(
                        isRunning: attachment.phase == .running,
                        canRelaunch: canRelaunch(attachment.phase),
                        controller: attachment.controller,
                        rename: {
                            renameTitle = summary?.title ?? ""
                            isRenamePresented = true
                        },
                        relaunch: { store.relaunchActiveTerminal() },
                        terminate: { isTerminateConfirmationPresented = true },
                        delete: { isDeleteConfirmationPresented = true }
                    )
                }
            } else {
                ProgressView("Opening Terminal…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: request) {
            store.openTerminal(request)
        }
        .onChange(of: attachment?.terminalID) { _, terminalID in
            if case .new = request, let terminalID {
                onCreated?(terminalID)
            }
        }
        .onChange(of: attachment?.phase, initial: true) { _, phase in
            guard case .exited = phase,
                !isDeletingExitedTerminal,
                let terminalID = attachment?.terminalID
            else { return }
            isDeletingExitedTerminal = true
            deleteTerminal(terminalID)
        }
        .alert("Rename Terminal", isPresented: $isRenamePresented) {
            TextField("Title", text: $renameTitle)
            Button("Rename") {
                if let terminalID = attachment?.terminalID {
                    store.renameTerminal(terminalID: terminalID, title: renameTitle)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Terminate this shell?",
            isPresented: $isTerminateConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Terminate Shell", role: .destructive) {
                if let terminalID = attachment?.terminalID {
                    store.terminateTerminal(terminalID: terminalID)
                }
            }
        } message: {
            Text("The running shell ends. The terminal stays in your Threads list and can be relaunched.")
        }
        .confirmationDialog(
            "Delete this terminal?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Terminal", role: .destructive) {
                if let terminalID = attachment?.terminalID {
                    deleteTerminal(terminalID)
                }
            }
        } message: {
            Text("The shell ends and the terminal is removed from your Threads list.")
        }
        .alert("Couldn’t Delete Terminal", isPresented: $isDeleteErrorPresented) {
            Button("OK") {}
        } message: {
            Text(deleteErrorMessage)
        }
    }

    private func deleteTerminal(_ terminalID: String) {
        Task {
            do {
                try await store.deleteTerminal(terminalID: terminalID)
                onDeleted?()
                dismiss()
            } catch {
                isDeletingExitedTerminal = false
                deleteErrorMessage = error.localizedDescription
                isDeleteErrorPresented = true
            }
        }
    }

    private func canRelaunch(_ phase: TerminalAttachment.Phase) -> Bool {
        switch phase {
        case .exited, .stopped, .failed: true
        case .attaching, .running, .disconnected: false
        }
    }
}

/// Toolbar content with narrow inputs so phase changes do not rebuild the
/// surface host.
private struct TerminalActionsToolbar: ToolbarContent {
    let isRunning: Bool
    let canRelaunch: Bool
    let controller: TerminalSessionController
    let rename: () -> Void
    let relaunch: () -> Void
    let terminate: () -> Void
    let delete: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu("Terminal Actions", systemImage: "ellipsis.circle") {
                Button("Rename", systemImage: "pencil", action: rename)
                if canRelaunch {
                    Button("Relaunch", systemImage: "arrow.clockwise", action: relaunch)
                }
                TerminalTextSizeMenu(controller: controller)
                if isRunning {
                    Button("Terminate", systemImage: "stop.circle", role: .destructive, action: terminate)
                }
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            }
            .accessibilityLabel("Terminal actions")
        }
    }
}

/// Text-size controls: the persisted preference applies to future terminals
/// and to the current surface through its configuration.
private struct TerminalTextSizeMenu: View {
    let controller: TerminalSessionController
    @State private var settings = TerminalSettings.shared

    var body: some View {
        Menu("Text Size", systemImage: "textformat.size") {
            Button("Larger", systemImage: "plus.magnifyingglass") {
                settings.increaseFontSize()
                controller.setFontSize(settings.fontSize)
            }
            .disabled(!settings.canIncrease)
            Button("Smaller", systemImage: "minus.magnifyingglass") {
                settings.decreaseFontSize()
                controller.setFontSize(settings.fontSize)
            }
            .disabled(!settings.canDecrease)
            Button("Reset", systemImage: "arrow.counterclockwise") {
                settings.resetFontSize()
                controller.setFontSize(settings.fontSize)
            }
        }
        .accessibilityLabel("Terminal text size")
    }
}

/// Connection/lifecycle overlay with narrow inputs so phase changes never
/// rebuild the terminal surface.
struct TerminalAttachmentOverlay: View {
    let phase: TerminalAttachment.Phase
    var canRelaunch = true
    var relaunch: () -> Void = {}

    var body: some View {
        switch phase {
        case .attaching:
            ProgressView("Connecting…")
                .padding()
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
        case .failed(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                if canRelaunch {
                    Button("Relaunch", systemImage: "arrow.clockwise", action: relaunch)
                }
            }
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        case .disconnected:
            Label("Reconnecting to maiD…", systemImage: "wifi.slash")
                .padding()
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
                .accessibilityLabel("Reconnecting to maiD")
        case .stopped:
            VStack(spacing: 12) {
                Label("Terminal stopped", systemImage: "stop.circle")
                Button("Relaunch", systemImage: "arrow.clockwise", action: relaunch)
            }
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        case .running, .exited:
            EmptyView()
        }
    }
}
